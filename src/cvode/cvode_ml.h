/***********************************************************************
 *                                                                     *
 *                   OCaml interface to Sundials                       *
 *                                                                     *
 *             Timothy Bourke, Jun Inoue, and Marc Pouzet              *
 *             (Inria/ENS)     (Inria/ENS)    (UPMC/ENS/Inria)         *
 *                                                                     *
 *  Copyright 2014 Institut National de Recherche en Informatique et   *
 *  en Automatique.  All rights reserved.  This file is distributed    *
 *  under a New BSD License, refer to the file LICENSE.                *
 *                                                                     *
 ***********************************************************************/

#ifndef _CVODE_ML_H__
#define _CVODE_ML_H__

#include <sundials/sundials_types.h>
#include <sundials/sundials_nvector.h>
#include <caml/mlvalues.h>

/*
 * The session data structure is shared in four parts across the OCaml and C
 * heaps:
 *
 *           C HEAP                 .             OCAML HEAP
 * ---------------------------------.-----------------------------------
 *                                  .       (Program using Sundials/ML)
 *                                  .                            |
 *              +---------------+   .   +-------------------+    |
 *              | generational  +------>| weak ref : Weak.t |    |
 *              | global root   |   .   +-------------------+    |
 *              | (type: value) |   .   | ~ ~ ~ ~ ~ ~ ~ ~ ~ |    |
 *              +---------------+   .   +----------------+--+    |
 *                      /|\  /|\    .                    |       |
 *                       |    |     .                    |       |
 *                       |    |     .                   \|/     \|/
 *                       |    |     .                 +----------------+
 *                       |    |     .                 |  session       |
 *   +------------+      |    |     .                 +----------------+
 *   | cvode_mem  |<----------------------------------+ cvode          |
 *   +------------+      |    +-----------------------+ backref        |
 *   |    ...     |      |          .                 | nroots         |
 *   |cv_user_data+------+          .                 | ls_callbacks   |
 *   |    ...     |                 .                 | ...            |
 *   +------------+                 .                 +----------------+
 *                                  .
 *
 *  * A cvode_mem structure is allocated by CVodeInit for each session. It
 *    is the "C side" of the session data structure.
 *
 *  * The "OCaml side" of the session data structure is a record which contains
 *    a pointer to cvode_mem, several data fields, and the callback closures.
 *    It is returned to users of the library and used like any other abstract
 *    data type in OCaml.
 *
 *  * cvode_mem holds an indirect reference to the session record as user data
 *    (set by CVodeSetUserData).  It cannot directly point to the record
 *    because the GC can change the record's address.  Instead, user data
 *    points to a global root which the GC updates whenever it relocates the
 *    session.  We cannot simply point cv_user_data to the weak reference and
 *    make it a global root, because we have no direct access to the members of
 *    cvode_mem.
 *
 *  * The global root points to a weak reference (a Weak.t of size 1) which
 *    points to the session record.  The root is destroyed when the session
 *    record is GC'ed -- note that if the root referenced the session record
 *    via a non-weak pointer the session would never be GC'ed, hence the root
 *    would never be destroyed either.
 *
 * 1. c_cvode_init() on the C side creates cvode_mem and the global root, and
 *    the OCaml side wraps that in a session record.  The OCaml side associates
 *    that record with a finalizer that unregisters the global root and frees
 *    all the C-side memory.
 *
 * 2. Callback functions (the right-hand side function, root function, etc)
 *    access the session through the user data.  This is the only way they can
 *    access the session.  The weak pointer is guaranteed to be alive during
 *    callback because the session record is alive.  The session record is
 *    captured in a C stack variable of type value when control enters the C
 *    stub that initiated the callback.
 *
 * 3. Other functions, like those that query integrator statistics, access the
 *    session record directly.
 *
 * 4. Eventually, when the user program abandons all references to the session
 *    record, the GC can reclaim the record because the only remaining direct
 *    reference to it is the weak pointer.
 *
 * NB: cv_user_data can't point directly to the session, unlike how in nvectors
 * (see nvector_ml.h) the backlink points directly to the payload.  This is
 * because the session contains the closure ls_callback, which may close over
 * the session in reasonable use cases.  In nvectors, by contrast, the payload
 * should be just an array of float's.
 */
/* Implementation note: we have also considered an arrangement where the global
 * root is replaced by a pointer of type value*.  The idea was that whenever
 * execution enters the C side, we capture the session record in a stack
 * variable (which is registered with OCaml's GC through CAMLparam()) and make
 * the pointer point to this stack variable.  The stack variable is updated by
 * GC, while the pointer pointing to the stack variable is always at the same
 * address.
 *
 * In the following figure, the GC sees everything on the stack and OCaml heap,
 * while seeing nothing on the C heap.
 *
 *           C HEAP         .     STACK     .        OCAML HEAP
 * -------------------------.---------------.---------------------------
 *   +-------------+        . +-----------+ . (Program using Sundials/ML)
 *   | pointer of  |        . |function   | .                     |
 *   | type value* +--------->|param of   +--------------+        |
 *   +-------------+        . |type value | .            |        |
 *         /|\              . +-----------+ .            |        |
 *          |               .               .           \|/      \|/
 *  +-------+               .  NB: This     .        +----------------+
 *  |                       .  diagram does .        |  session       |
 *  |  +--------------+     .  NOT show how .        +----------------+
 *  |  |  cvode_mem   |<-----  the current  ---------+ cvode          |
 *  |  +--------------+     .  code works!! .        | nroots         |
 *  |  |     ...      |     .  The diagram  .        | closure_rhsfn  |
 *  +--+ cv_user_data |     .  above does!! .        | closure_rootsfn|
 *     | conceptually |     .               .        | ...            |
 *     | of type      |     .               .        |                |
 *     | value **     |     .               .        +----------------+
 *     |     ...      |     .               .
 *     +--------------+     .               .
 *
 * On the one hand, we dropped this approach because it's invasive and
 * error-prone.  The error handler callback (errh) needs to access the session
 * record too, and almost every Sundials API can potentially call this handler.
 * This means that every C stub must update the pointer before doing anything
 * else (including functions that do not ostensibly initiate any callbacks),
 * and we have to ensure that callbacks never see the pointer pointing to an
 * expired stack variable.
 *
 * On the other hand, this approach is probably more efficient than the current
 * approach with weak tables.  Perhaps if the callback overhead is found to be
 * a major bottleneck, we can switch over to this alternative.
 */

void sunml_cvode_check_flag(const char *call, int flag, void *cvode_mem);
#if 400 <= SUNDIALS_LIB_VERSION
void sunml_cvode_check_ls_flag(const char *call, int flag);
#else
void sunml_cvode_check_dls_flag(const char *call, int flag);
void sunml_cvode_check_spils_flag(const char *call, int flag);
#endif

value sunml_cvode_make_jac_arg(realtype t, N_Vector y, N_Vector fy, value tmp);
value sunml_cvode_make_triple_tmp(N_Vector tmp1, N_Vector tmp2, N_Vector tmp3);

value sunml_cvode_last_lin_exception(void *cvode_mem);

#define CHECK_FLAG(call, flag) if (flag != CV_SUCCESS) \
				 sunml_cvode_check_flag(call, flag, NULL)
#if 400 <= SUNDIALS_LIB_VERSION
#define CHECK_LS_FLAG(call, flag) if (flag != CVLS_SUCCESS) \
				 sunml_cvode_check_ls_flag(call, flag)
#else
#define CHECK_SPILS_FLAG(call, flag) if (flag != CVSPILS_SUCCESS) \
				 sunml_cvode_check_spils_flag(call, flag)
#define CHECK_DLS_FLAG(call, flag) if (flag != CVDLS_SUCCESS) \
				 sunml_cvode_check_dls_flag(call, flag)
#endif

typedef enum {
    UNRECOVERABLE = 0,
    RECOVERABLE = 1
} recoverability;

int sunml_cvode_translate_exception (value session, value exn_result,
			       recoverability recoverable);

/* Check return value of a callback.  The common (no-error) case is
 * handled without setting up a new caml frame with CAMLparam.
 * Evaluates to:
 *   0 if result is not an exception
 *   1 if result is RecoverableFailure and recoverable == RECOVERABLE
 *  -1 otherwise, and records the exception in result in the session */
#define CHECK_EXCEPTION(session, result, recoverable)			\
    (Is_exception_result (result)					\
     ? sunml_cvode_translate_exception (session,				\
				  result = Extract_exception (result),	\
				  recoverable)				\
     : 0)

/* Interface with OCaml types */

/* Indices into the Cvode_*.session type.  This enum must be in the same order
 * as the session type's member declaration.  */
enum cvode_session_index {
    RECORD_CVODE_SESSION_CVODE = 0,
    RECORD_CVODE_SESSION_BACKREF,
    RECORD_CVODE_SESSION_NROOTS,
    RECORD_CVODE_SESSION_CHECKVEC,
    RECORD_CVODE_SESSION_EXN_TEMP,
    RECORD_CVODE_SESSION_RHSFN,
    RECORD_CVODE_SESSION_ROOTSFN,
    RECORD_CVODE_SESSION_ERRH,
    RECORD_CVODE_SESSION_ERRW,
    RECORD_CVODE_SESSION_PROJFN,
    RECORD_CVODE_SESSION_MONITORFN,
    RECORD_CVODE_SESSION_LS_SOLVER,
    RECORD_CVODE_SESSION_LS_CALLBACKS,
    RECORD_CVODE_SESSION_LS_PRECFNS,
    RECORD_CVODE_SESSION_NLS_SOLVER,
    RECORD_CVODE_SESSION_SENSEXT,
    RECORD_CVODE_SESSION_SIZE,	/* This has to come last.  */
};

#define CVODE_MEM(v) (*(void **)Data_custom_val(v))
#define CVODE_MEM_FROM_ML(v) (CVODE_MEM(Field((v), RECORD_CVODE_SESSION_CVODE)))
#define CVODE_BACKREF_FROM_ML(v) \
    ((value *)(Field((v), RECORD_CVODE_SESSION_BACKREF)))
#define CVODE_NROOTS_FROM_ML(v) \
  Long_val(Field((v), RECORD_CVODE_SESSION_NROOTS))
#define CVODE_ROOTSFN_FROM_ML(v)    Field((v), RECORD_CVODE_SESSION_ROOTSFN)
#define CVODE_LS_CALLBACKS_FROM_ML(v) Field((v), RECORD_CVODE_SESSION_LS_CALLBACKS)
#define CVODE_LS_PRECFNS_FROM_ML(v) Field((v), RECORD_CVODE_SESSION_LS_PRECFNS)
#define CVODE_SENSEXT_FROM_ML(v) Field(Field((v), RECORD_CVODE_SESSION_SENSEXT), 0)

enum cvode_spils_precfns_index {
  RECORD_CVODE_SPILS_PRECFNS_PREC_SOLVE_FN   = 0,
  RECORD_CVODE_SPILS_PRECFNS_PREC_SETUP_FN,
  RECORD_CVODE_SPILS_PRECFNS_SIZE
};

enum cvode_bbd_precfns_index {
  RECORD_CVODE_BBD_PRECFNS_LOCAL_FN = 0,
  RECORD_CVODE_BBD_PRECFNS_COMM_FN,
  RECORD_CVODE_BBD_PRECFNS_SIZE
};

enum cvode_lmm_tag {
  VARIANT_CVODE_LMM_ADAMS = 0,
  VARIANT_CVODE_LMM_BDF,
};

enum cvode_bandrange_index {
  RECORD_CVODE_BANDRANGE_MUPPER = 0,
  RECORD_CVODE_BANDRANGE_MLOWER,
  RECORD_CVODE_BANDRANGE_SIZE
};

enum cvode_solver_result_tag {
  VARIANT_CVODE_SOLVER_RESULT_SUCCESS        = 0,
  VARIANT_CVODE_SOLVER_RESULT_ROOTSFOUND,
  VARIANT_CVODE_SOLVER_RESULT_STOPTIMEREACHED,
};

enum cvode_integrator_stats_index {
  RECORD_CVODE_INTEGRATOR_STATS_STEPS		       = 0,
  RECORD_CVODE_INTEGRATOR_STATS_RHS_EVALS,
  RECORD_CVODE_INTEGRATOR_STATS_LINEAR_SOLVER_SETUPS,
  RECORD_CVODE_INTEGRATOR_STATS_ERROR_TEST_FAILURES,
  RECORD_CVODE_INTEGRATOR_STATS_LAST_INTERNAL_ORDER,
  RECORD_CVODE_INTEGRATOR_STATS_NEXT_INTERNAL_ORDER,
  RECORD_CVODE_INTEGRATOR_STATS_INITIAL_STEP_SIZE,
  RECORD_CVODE_INTEGRATOR_STATS_LAST_STEP_SIZE,
  RECORD_CVODE_INTEGRATOR_STATS_NEXT_STEP_SIZE,
  RECORD_CVODE_INTEGRATOR_STATS_INTERNAL_TIME,
  RECORD_CVODE_INTEGRATOR_STATS_SIZE
};

enum cvode_linear_solver_stats_index {
  RECORD_CVODE_LINEAR_SOLVER_STATS_JAC_EVALS = 0,
  RECORD_CVODE_LINEAR_SOLVER_STATS_LIN_RHS_EVALS,
  RECORD_CVODE_LINEAR_SOLVER_STATS_LIN_ITERS,
  RECORD_CVODE_LINEAR_SOLVER_STATS_LIN_CONV_FAILS,
  RECORD_CVODE_LINEAR_SOLVER_STATS_PREC_EVALS,
  RECORD_CVODE_LINEAR_SOLVER_STATS_PREC_SOLVES,
  RECORD_CVODE_LINEAR_SOLVER_STATS_JTSETUP_EVALS,
  RECORD_CVODE_LINEAR_SOLVER_STATS_JTIMES_EVALS,
  RECORD_CVODE_LINEAR_SOLVER_STATS_SIZE
};

enum cvode_jacobian_arg_index {
  RECORD_CVODE_JACOBIAN_ARG_JAC_T   = 0,
  RECORD_CVODE_JACOBIAN_ARG_JAC_Y,
  RECORD_CVODE_JACOBIAN_ARG_JAC_FY,
  RECORD_CVODE_JACOBIAN_ARG_JAC_TMP,
  RECORD_CVODE_JACOBIAN_ARG_SIZE
};

enum cvode_spils_solve_arg_index {
  RECORD_CVODE_SPILS_SOLVE_ARG_RHS   = 0,
  RECORD_CVODE_SPILS_SOLVE_ARG_GAMMA,
  RECORD_CVODE_SPILS_SOLVE_ARG_DELTA,
  RECORD_CVODE_SPILS_SOLVE_ARG_LEFT,
  RECORD_CVODE_SPILS_SOLVE_ARG_SIZE
};

enum cvode_bandblock_bandwidths_index {
  RECORD_CVODE_BANDBLOCK_BANDWIDTHS_MUDQ = 0,
  RECORD_CVODE_BANDBLOCK_BANDWIDTHS_MLDQ,
  RECORD_CVODE_BANDBLOCK_BANDWIDTHS_MUKEEP,
  RECORD_CVODE_BANDBLOCK_BANDWIDTHS_MLKEEP,
  RECORD_CVODE_BANDBLOCK_BANDWIDTHS_SIZE
};

/* This enum must list exceptions in the same order as the call to
 * c_register_exns in cvode.ml.  */
enum cvode_exn_index {
    CVODE_EXN_IllInput = 0,
    CVODE_EXN_TooClose,
    CVODE_EXN_TooMuchWork,
    CVODE_EXN_TooMuchAccuracy,
    CVODE_EXN_ErrFailure,
    CVODE_EXN_ConvergenceFailure,
    CVODE_EXN_LinearInitFailure,
    CVODE_EXN_LinearSetupFailure,
    CVODE_EXN_LinearSolveFailure,
    CVODE_EXN_NonlinearFailure,
    CVODE_EXN_NonlinearInitFailure,
    CVODE_EXN_NonlinearSetupFailure,
    CVODE_EXN_RhsFuncFailure,
    CVODE_EXN_FirstRhsFuncFailure,
    CVODE_EXN_RepeatedRhsFuncFailure,
    CVODE_EXN_UnrecoverableRhsFuncFailure,
    CVODE_EXN_RootFuncFailure,
    CVODE_EXN_ConstraintFailure,
    CVODE_EXN_BadK,
    CVODE_EXN_BadT,
    CVODE_EXN_VectorOpErr,
    CVODE_EXN_ProjFuncFailure,
    CVODE_EXN_RepeatedProjFuncError,
    CVODE_EXN_ProjectionNotEnabled,
    CVODE_EXN_SET_SIZE
};

#define CVODE_EXN(name)     REGISTERED_EXN(CVODE, name)
#define CVODE_EXN_TAG(name) REGISTERED_EXN_TAG(CVODE, name)

#endif
