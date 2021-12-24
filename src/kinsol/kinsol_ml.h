/***********************************************************************
 *                                                                     *
 *               OCaml interface to (serial) Sundials                  *
 *                                                                     *
 *             Timothy Bourke, Jun Inoue, and Marc Pouzet              *
 *             (Inria/ENS)     (Inria/ENS)    (UPMC/ENS/Inria)         *
 *                                                                     *
 *  Copyright 2014 Institut National de Recherche en Informatique et   *
 *  en Automatique.  All rights reserved.  This file is distributed    *
 *  under a New BSD License, refer to the file LICENSE.                *
 *                                                                     *
 ***********************************************************************/

#ifndef _KINSOL_ML_H__
#define _KINSOL_ML_H__

#include "../sundials/sundials_ml.h"
#include "../nvectors/nvector_ml.h"
#include <caml/mlvalues.h>

void sunml_kinsol_check_flag(const char *call, int flag, void *kin_mem);
#if 400 <= SUNDIALS_LIB_VERSION
void sunml_kinsol_check_ls_flag(const char *call, int flag);
#else
void sunml_kinsol_check_dls_flag(const char *call, int flag);
void sunml_kinsol_check_spils_flag(const char *call, int flag);
#endif

value sunml_kinsol_make_jac_arg(N_Vector u, N_Vector fu, value tmp);
value sunml_kinsol_make_double_tmp(N_Vector tmp1, N_Vector tmp2);

#define CHECK_FLAG(call, flag) if (flag != KIN_SUCCESS) \
				 sunml_kinsol_check_flag(call, flag, NULL)
#if 400 <= SUNDIALS_LIB_VERSION
#define CHECK_LS_FLAG(call, flag) if (flag != KINLS_SUCCESS) \
				 sunml_kinsol_check_ls_flag(call, flag)
#else
#define CHECK_SPILS_FLAG(call, flag) if (flag != KINSPILS_SUCCESS) \
				 sunml_kinsol_check_spils_flag(call, flag)
#define CHECK_DLS_FLAG(call, flag) if (flag != KINDLS_SUCCESS) \
				 sunml_kinsol_check_dls_flag(call, flag)
#endif

typedef enum {
    UNRECOVERABLE = 0,
    RECOVERABLE = 1
} recoverability;

int sunml_kinsol_translate_exception (value session, value exn_result,
				recoverability recoverable);

/* Check return value of a callback.  The common (no-error) case is
 * handled without setting up a new caml frame with CAMLparam.
 * Evaluates to:
 *   0 if result is not an exception
 *   1 if result is RecoverableFailure and recoverable == RECOVERABLE
 *  -1 otherwise, and records the exception in result in the session */
#define CHECK_EXCEPTION(session, result, recoverable)			\
    (Is_exception_result (result)					\
     ? sunml_kinsol_translate_exception (session, result, recoverable)	\
     : 0)

/* Indices into the Kinsol_*.session type.  This enum must be in the same order as
 * the session type's member declaration.  The session data structure is shared
 * in four parts across the OCaml and C heaps.  See cvode_ml.h for details.
 */
enum kinsol_index {
    RECORD_KINSOL_SESSION_MEM = 0,
    RECORD_KINSOL_SESSION_BACKREF,
    RECORD_KINSOL_SESSION_INITVEC,
    RECORD_KINSOL_SESSION_CHECKVEC,
    RECORD_KINSOL_SESSION_CONTEXT,
    RECORD_KINSOL_SESSION_NEQS,
    RECORD_KINSOL_SESSION_EXN_TEMP,
    RECORD_KINSOL_SESSION_SYSFN,
    RECORD_KINSOL_SESSION_ERRH,
    RECORD_KINSOL_SESSION_INFOH,
    RECORD_KINSOL_SESSION_ERROR_FILE,
    RECORD_KINSOL_SESSION_INFO_FILE,
    RECORD_KINSOL_SESSION_LS_SOLVER,
    RECORD_KINSOL_SESSION_LS_CALLBACKS,
    RECORD_KINSOL_SESSION_LS_PRECFNS,
    RECORD_KINSOL_SESSION_SIZE	/* This has to come last. */
};

#define KINSOL_NEQS_FROM_ML(v)  Long_val(Field((v), RECORD_KINSOL_SESSION_NEQS))
#define KINSOL_LS_CALLBACKS_FROM_ML(v) (Field((v), RECORD_KINSOL_SESSION_LS_CALLBACKS))
#define KINSOL_LS_PRECFNS_FROM_ML(v) (Field((v), RECORD_KINSOL_SESSION_LS_PRECFNS))
#define KINSOL_SYSFN_FROM_ML(v) (Field((v), RECORD_KINSOL_SESSION_SYSFN))
#define KINSOL_ERRH_FROM_ML(v) (Field((v), RECORD_KINSOL_SESSION_ERRH))
#define KINSOL_INFOH_FROM_ML(v) (Field((v), RECORD_KINSOL_SESSION_INFOH))

enum kinsol_bandrange_index {
  RECORD_KINSOL_BANDRANGE_MUPPER = 0,
  RECORD_KINSOL_BANDRANGE_MLOWER,
  RECORD_KINSOL_BANDRANGE_SIZE
};

#define KINSOL_MEM(v) (SUNML_MEM(v))
#define KINSOL_MEM_FROM_ML(v) \
    (KINSOL_MEM(Field((v), RECORD_KINSOL_SESSION_MEM)))
#define KINSOL_BACKREF_FROM_ML(v) \
    ((value *)(Field((v), RECORD_KINSOL_SESSION_BACKREF)))

enum kinsol_spils_prec_solve_arg_index {
  RECORD_KINSOL_SPILS_PREC_SOLVE_ARG_USCALE = 0,
  RECORD_KINSOL_SPILS_PREC_SOLVE_ARG_FSCALE,
  RECORD_KINSOL_SPILS_PREC_SOLVE_ARG_SIZE
};

enum kinsol_spils_precfns_index {
  RECORD_KINSOL_SPILS_PRECFNS_PREC_SOLVE_FN = 0,
  RECORD_KINSOL_SPILS_PRECFNS_PREC_SETUP_FN,
  RECORD_KINSOL_SPILS_PRECFNS_SIZE
};

enum kinsol_bbd_precfns_index {
  RECORD_KINSOL_BBD_PRECFNS_LOCAL_FN = 0,
  RECORD_KINSOL_BBD_PRECFNS_COMM_FN,
  RECORD_KINSOL_BBD_PRECFNS_SIZE
};

enum kinsol_jacobian_arg_index {
  RECORD_KINSOL_JACOBIAN_ARG_JAC_U   = 0,
  RECORD_KINSOL_JACOBIAN_ARG_JAC_FU,
  RECORD_KINSOL_JACOBIAN_ARG_JAC_TMP,
  RECORD_KINSOL_JACOBIAN_ARG_SIZE
};

enum kinsol_strategy_tag {
  VARIANT_KINSOL_STRATEGY_NEWTON = 0,
  VARIANT_KINSOL_STRATEGY_LINESEARCH,
  VARIANT_KINSOL_STRATEGY_PICARD,
  VARIANT_KINSOL_STRATEGY_FIXEDPOINT,
};

enum kinsol_print_level_tag {
  VARIANT_KINSOL_PRINT_LEVEL_NO_INFORMATION = 0,
  VARIANT_KINSOL_PRINT_LEVEL_SHOW_SCALED_NORMS,
  VARIANT_KINSOL_PRINT_LEVEL_SHOW_SCALED_DFNORM,
  VARIANT_KINSOL_PRINT_LEVEL_SHOW_GLOBAL_VALUES,
};

enum kinsol_eta_params_index {
  RECORD_KINSOL_ETA_PARAMS_EGAMMA = 0,
  RECORD_KINSOL_ETA_PARAMS_EALPHA,
  RECORD_KINSOL_ETA_PARAMS_SIZE
};

enum kinsol_eta_choice_tag {
  /* untagged: */
  VARIANT_KINSOL_ETA_CHOICE1 = 0,
  /* tagged: */
  VARIANT_KINSOL_ETA_CHOICE2 = 0,
  VARIANT_KINSOL_ETA_CONSTANT
};

enum kinsol_result_tag {
  VARIANT_KINSOL_RESULT_SUCCESS = 0,
  VARIANT_KINSOL_RESULT_INITIAL_GUESS_OK,
  VARIANT_KINSOL_RESULT_STOPPED_ON_STEP_TOL
};

enum kinsol_orthaa_tag {
  VARIANT_KINSOL_ORTHAA_MGS = 0,
  VARIANT_KINSOL_ORTHAA_ICWY,
  VARIANT_KINSOL_ORTHAA_CGS2,
  VARIANT_KINSOL_ORTHAA_DCGS2,
};

enum kinsol_bandblock_bandwidths_index {
  RECORD_KINSOL_BANDBLOCK_BANDWIDTHS_MUDQ = 0,
  RECORD_KINSOL_BANDBLOCK_BANDWIDTHS_MLDQ,
  RECORD_KINSOL_BANDBLOCK_BANDWIDTHS_MUKEEP,
  RECORD_KINSOL_BANDBLOCK_BANDWIDTHS_MLKEEP,
  RECORD_KINSOL_BANDBLOCK_BANDWIDTHS_SIZE
};

/* This enum must list exceptions in the same order as the call to
 * c_register_exns in kinsol.ml.  */
enum kinsol_exn_index {
    KINSOL_EXN_IllInput = 0,
    KINSOL_EXN_LineSearchNonConvergence,
    KINSOL_EXN_MaxIterationsReached,
    KINSOL_EXN_MaxNewtonStepExceeded,
    KINSOL_EXN_LineSearchBetaConditionFailure,
    KINSOL_EXN_LinearSolverNoRecovery,
    KINSOL_EXN_LinearSolverInitFailure,
    KINSOL_EXN_LinearSetupFailure,
    KINSOL_EXN_LinearSolveFailure,
    KINSOL_EXN_SystemFunctionFailure,
    KINSOL_EXN_FirstSystemFunctionFailure,
    KINSOL_EXN_RepeatedSystemFunctionFailure,
    KINSOL_EXN_VectorOpErr,
    KINSOL_EXN_SET_SIZE,
};

#define KINSOL_EXN(name)     REGISTERED_EXN(KINSOL, name)
#define KINSOL_EXN_TAG(name) REGISTERED_EXN_TAG(KINSOL, name)


#endif
