%
% (c) The University of Glasgow 2006
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%

The Desugarer: turning HsSyn into Core.

\begin{code}
module Desugar ( deSugar, deSugarExpr ) where

#include "HsVersions.h"

import DynFlags
import StaticFlags
import HscTypes
import HsSyn
import TcRnTypes
import MkIface
import Id
import Name
import CoreSyn
import PprCore
import DsMonad
import DsExpr
import DsBinds
import DsForeign
import DsExpr		()	-- Forces DsExpr to be compiled; DsBinds only
				-- depends on DsExpr.hi-boot.
import Module
import UniqFM
import PackageConfig
import RdrName
import NameSet
import VarSet
import Rules
import CoreLint
import CoreFVs
import ErrUtils
import ListSetOps
import Outputable
import SrcLoc
import Maybes
import FastString
import Util
import Coverage
import IOEnv
import Data.IORef

\end{code}

%************************************************************************
%*									*
%* 		The main function: deSugar
%*									*
%************************************************************************

\begin{code}
deSugar :: HscEnv -> ModLocation -> TcGblEnv -> IO (Maybe ModGuts)
-- Can modify PCS by faulting in more declarations

deSugar hsc_env 
        mod_loc
        tcg_env@(TcGblEnv { tcg_mod          = mod,
			    tcg_src	     = hsc_src,
		    	    tcg_type_env     = type_env,
		    	    tcg_imports      = imports,
		    	    tcg_exports      = exports,
		    	    tcg_dus	     = dus, 
		    	    tcg_inst_uses    = dfun_uses_var,
			    tcg_th_used      = th_var,
			    tcg_keep	     = keep_var,
		    	    tcg_rdr_env      = rdr_env,
		    	    tcg_fix_env      = fix_env,
		    	    tcg_fam_inst_env = fam_inst_env,
	    	    	    tcg_deprecs      = deprecs,
			    tcg_binds        = binds,
			    tcg_fords        = fords,
			    tcg_rules        = rules,
		    	    tcg_insts        = insts,
		    	    tcg_fam_insts    = fam_insts })
  = do	{ showPass dflags "Desugar"

	-- Desugar the program
        ; let export_set = availsToNameSet exports
	; let auto_scc = mkAutoScc mod export_set
        ; let noDbgSites = []
	; mb_res <- case ghcMode dflags of
	             JustTypecheck -> return (Just ([], [], NoStubs, noHpcInfo, noDbgSites))
                     _        -> do (binds_cvr,ds_hpc_info) 
					      <- if opt_Hpc
                                                 then addCoverageTicksToBinds dflags mod mod_loc binds
                                                 else return (binds, noHpcInfo)
                                    initDs hsc_env mod rdr_env type_env $ do
		                        { core_prs <- dsTopLHsBinds auto_scc binds_cvr
		                        ; (ds_fords, foreign_prs) <- dsForeigns fords
		                        ; let all_prs = foreign_prs ++ core_prs
		                              local_bndrs = mkVarSet (map fst all_prs)
		                        ; ds_rules <- mappM (dsRule mod local_bndrs) rules
		                        ; return (all_prs, catMaybes ds_rules, ds_fords, ds_hpc_info)
                                        ; dbgSites_var <- getBkptSitesDs
                                        ; dbgSites <- ioToIOEnv$ readIORef dbgSites_var
		                        ; return (all_prs, catMaybes ds_rules, ds_fords, ds_hpc_info, dbgSites)
		                        }
	; case mb_res of {
	   Nothing -> return Nothing ;
	   Just (all_prs, ds_rules, ds_fords,ds_hpc_info, dbgSites) -> do

	{ 	-- Add export flags to bindings
	  keep_alive <- readIORef keep_var
	; let final_prs = addExportFlags ghci_mode export_set
                                 keep_alive all_prs ds_rules
	      ds_binds  = [Rec final_prs]
	-- Notice that we put the whole lot in a big Rec, even the foreign binds
	-- When compiling PrelFloat, which defines data Float = F# Float#
	-- we want F# to be in scope in the foreign marshalling code!
	-- You might think it doesn't matter, but the simplifier brings all top-level
	-- things into the in-scope set before simplifying; so we get no unfolding for F#!

	-- Lint result if necessary
	; endPass dflags "Desugar" Opt_D_dump_ds ds_binds

	-- Dump output
	; doIfSet (dopt Opt_D_dump_ds dflags) 
		  (printDump (ppr_ds_rules ds_rules))

	; dfun_uses <- readIORef dfun_uses_var		-- What dfuns are used
	; th_used   <- readIORef th_var			-- Whether TH is used
	; let used_names = allUses dus `unionNameSets` dfun_uses
	      pkgs | th_used   = insertList thPackageId (imp_dep_pkgs imports)
	      	   | otherwise = imp_dep_pkgs imports

	      dep_mods = eltsUFM (delFromUFM (imp_dep_mods imports) (moduleName mod))
		-- M.hi-boot can be in the imp_dep_mods, but we must remove
		-- it before recording the modules on which this one depends!
		-- (We want to retain M.hi-boot in imp_dep_mods so that 
		--  loadHiBootInterface can see if M's direct imports depend 
		--  on M.hi-boot, and hence that we should do the hi-boot consistency 
		--  check.)

	      dir_imp_mods = imp_mods imports

	; usages <- mkUsageInfo hsc_env dir_imp_mods dep_mods used_names

	; let 
		-- Modules don't compare lexicographically usually, 
		-- but we want them to do so here.
	     le_mod :: Module -> Module -> Bool	 
	     le_mod m1 m2 = moduleNameFS (moduleName m1) 
				<= moduleNameFS (moduleName m2)
	     le_dep_mod :: (ModuleName, IsBootInterface) -> (ModuleName, IsBootInterface) -> Bool	 
	     le_dep_mod (m1,_) (m2,_) = moduleNameFS m1 <= moduleNameFS m2

	     deps = Deps { dep_mods   = sortLe le_dep_mod dep_mods,
			   dep_pkgs   = sortLe (<=)   pkgs,	
			   dep_orphs  = sortLe le_mod (imp_orphs  imports),
			   dep_finsts = sortLe le_mod (imp_finsts imports) }
		-- sort to get into canonical order

	     mod_guts = ModGuts {	
		mg_module    	= mod,
		mg_boot	     	= isHsBoot hsc_src,
		mg_exports   	= exports,
		mg_deps	     	= deps,
		mg_usages    	= usages,
		mg_dir_imps  	= [m | (m,_,_) <- moduleEnvElts dir_imp_mods],
	        mg_rdr_env   	= rdr_env,
		mg_fix_env   	= fix_env,
		mg_deprecs   	= deprecs,
		mg_types     	= type_env,
		mg_insts     	= insts,
		mg_fam_insts 	= fam_insts,
		mg_fam_inst_env = fam_inst_env,
	        mg_rules     	= ds_rules,
		mg_binds     	= ds_binds,
		mg_foreign   	= ds_fords,
		mg_hpc_info  	= ds_hpc_info,
                mg_dbg_sites 	= dbgSites }
        ; return (Just mod_guts)
	}}}

  where
    dflags    = hsc_dflags hsc_env
    ghci_mode = ghcMode (hsc_dflags hsc_env)

mkAutoScc :: Module -> NameSet -> AutoScc
mkAutoScc mod exports
  | not opt_SccProfilingOn 	-- No profiling
  = NoSccs		
  | opt_AutoSccsOnAllToplevs 	-- Add auto-scc on all top-level things
  = AddSccs mod (\id -> True)
  | opt_AutoSccsOnExportedToplevs	-- Only on exported things
  = AddSccs mod (\id -> idName id `elemNameSet` exports)
  | otherwise
  = NoSccs


deSugarExpr :: HscEnv
	    -> Module -> GlobalRdrEnv -> TypeEnv 
 	    -> LHsExpr Id
	    -> IO (Maybe CoreExpr)
-- Prints its own errors; returns Nothing if error occurred

deSugarExpr hsc_env this_mod rdr_env type_env tc_expr
  = do	{ let dflags = hsc_dflags hsc_env
	; showPass dflags "Desugar"

	-- Do desugaring
	; mb_core_expr <- initDs hsc_env this_mod rdr_env type_env $
			  dsLExpr tc_expr

	; case mb_core_expr of {
	    Nothing   -> return Nothing ;
	    Just expr -> do {

		-- Dump output
	  dumpIfSet_dyn dflags Opt_D_dump_ds "Desugared" (pprCoreExpr expr)

        ; return (Just expr) } } }

--		addExportFlags
-- Set the no-discard flag if either 
--	a) the Id is exported
--	b) it's mentioned in the RHS of an orphan rule
--	c) it's in the keep-alive set
--
-- It means that the binding won't be discarded EVEN if the binding
-- ends up being trivial (v = w) -- the simplifier would usually just 
-- substitute w for v throughout, but we don't apply the substitution to
-- the rules (maybe we should?), so this substitution would make the rule
-- bogus.

-- You might wonder why exported Ids aren't already marked as such;
-- it's just because the type checker is rather busy already and
-- I didn't want to pass in yet another mapping.

addExportFlags ghci_mode exports keep_alive prs rules
  = [(add_export bndr, rhs) | (bndr,rhs) <- prs]
  where
    add_export bndr
	| dont_discard bndr = setIdExported bndr
	| otherwise	    = bndr

    orph_rhs_fvs = unionVarSets [ ruleRhsFreeVars rule
			        | rule <- rules, 
				  not (isLocalRule rule) ]
	-- A non-local rule keeps alive the free vars of its right-hand side. 
	-- (A "non-local" is one whose head function is not locally defined.)
	-- Local rules are (later, after gentle simplification) 
	-- attached to the Id, and that keeps the rhs free vars alive.

    dont_discard bndr = is_exported name
		     || name `elemNameSet` keep_alive
		     || bndr `elemVarSet` orph_rhs_fvs 
		     where
			name = idName bndr

    	-- In interactive mode, we don't want to discard any top-level
    	-- entities at all (eg. do not inline them away during
    	-- simplification), and retain them all in the TypeEnv so they are
    	-- available from the command line.
	--
	-- isExternalName separates the user-defined top-level names from those
	-- introduced by the type checker.
    is_exported :: Name -> Bool
    is_exported | ghci_mode == Interactive = isExternalName
		| otherwise 		   = (`elemNameSet` exports)

ppr_ds_rules [] = empty
ppr_ds_rules rules
  = text "" $$ text "-------------- DESUGARED RULES -----------------" $$
    pprRules rules
\end{code}



%************************************************************************
%*									*
%* 		Desugaring transformation rules
%*									*
%************************************************************************

\begin{code}
dsRule :: Module -> IdSet -> LRuleDecl Id -> DsM (Maybe CoreRule)
dsRule mod in_scope (L loc (HsRule name act vars lhs tv_lhs rhs fv_rhs))
  = putSrcSpanDs loc $ 
    do	{ let bndrs     = [var | RuleBndr (L _ var) <- vars]
	; lhs'  <- dsLExpr lhs
	; rhs'  <- dsLExpr rhs

	; case decomposeRuleLhs bndrs lhs' of {
		Nothing -> do { warnDs msg; return Nothing } ;
		Just (bndrs', fn_id, args) -> do
	
	-- Substitute the dict bindings eagerly,
	-- and take the body apart into a (f args) form
	{ let local_rule = nameIsLocalOrFrom mod fn_name
		-- NB we can't use isLocalId in the orphan test, 
		-- because isLocalId isn't true of class methods
	      fn_name   = idName fn_id
	      lhs_names = fn_name : nameSetToList (exprsFreeNames args)
		-- No need to delete bndrs, because
		-- exprsFreeNames finds only External names

		-- A rule is an orphan only if none of the variables
		-- mentioned on its left-hand side are locally defined
	      orph = case filter (nameIsLocalOrFrom mod) lhs_names of
			(n:ns) -> Just (nameOccName n)
			[]     -> Nothing

	      rule = Rule { ru_name = name, ru_fn = fn_name, ru_act = act,
			    ru_bndrs = bndrs', ru_args = args, ru_rhs = rhs', 
			    ru_rough = roughTopNames args, 
			    ru_local = local_rule, ru_orph = orph }
	; return (Just rule)
	} } }
  where
    msg = hang (ptext SLIT("RULE left-hand side too complicated to desugar; ignored"))
	     2 (ppr lhs)
\end{code}
