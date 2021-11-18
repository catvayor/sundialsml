(***********************************************************************)
(*                                                                     *)
(*                   OCaml interface to Sundials                       *)
(*                                                                     *)
(*  Timothy Bourke (Inria), Jun Inoue (Inria), and Marc Pouzet (LIENS) *)
(*                                                                     *)
(*  Copyright 2014 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under a New BSD License, refer to the file LICENSE.                *)
(*                                                                     *)
(***********************************************************************)

open Sundials

(* Hack to ensure that Sundials.c_init_module is executed so that the global
   exceptions are properly registered. *)
let e = Sundials.RecoverableFailure

(* Types shared between Ida, Idas, Ida_bbd, and Idas_bbd.  See the
   notes on Cvode_impl about the rationale behind this module.  *)

(*
 * NB: The order of variant constructors and record fields is important!
 *     If these types are changed or augmented, the corresponding declarations
 *     in cvode_ml.h (and code in cvode_ml.c) must also be updated.
 *)

(* Dummy callbacks.  These dummes getting called indicates a fatal
   bug.  Rather than raise an exception (which may or may not get
   propagated properly depending on the context), we immediately abort
   the program. *)

type 'a double = 'a * 'a
type 'a triple = 'a * 'a * 'a

type ('data, 'kind) nvector = ('data, 'kind) Nvector.t
module LSI = Sundials_LinearSolver_impl
module NLSI = Sundials_NonlinearSolver_impl

type ('t, 'a) jacobian_arg =
  {
    jac_t    : float;
    jac_y    : 'a;
    jac_y'   : 'a;
    jac_res  : 'a;
    jac_coef : float;
    jac_tmp  : 't
  }

module DirectTypes = struct
  type 'm jac_fn =
    (RealArray.t triple, RealArray.t) jacobian_arg
    -> 'm
    -> unit

  (* These fields are accessed from cvode_ml.c *)
  type 'm jac_callback =
    {
      jacfn: 'm jac_fn;
      mutable jmat : 'm option (* Not used in Sundials >= 3.0.0 *)
    }

  let no_callback = fun _ _ -> Sundials_impl.crash "no direct callback"
end

module SpilsTypes' = struct

  type 'a prec_solve_fn =
    (unit, 'a) jacobian_arg
    -> 'a
    -> 'a
    -> float
    -> unit

  type 'a prec_setup_fn = (unit, 'a) jacobian_arg -> unit

  type 'd jac_times_setup_fn =
    (unit, 'd) jacobian_arg
    -> unit

  type 'a jac_times_vec_fn =
    ('a double, 'a) jacobian_arg
    -> 'a           (* v *)
    -> 'a           (* Jv *)
    -> unit

  type 'a precfns =
    {
      prec_solve_fn : 'a prec_solve_fn;
      prec_setup_fn : 'a prec_setup_fn option;
    }
end

module IdaBbdParamTypes = struct
  type 'a local_fn = float -> 'a -> 'a -> 'a  -> unit
  type 'a comm_fn = float -> 'a -> 'a -> unit
  type 'a precfns =
    {
      local_fn : 'a local_fn;
      comm_fn  : 'a comm_fn option;
    }
end

module IdaBbdTypes = struct
  type bandwidths =
    {
      mudq    : int;
      mldq    : int;
      mukeep  : int;
      mlkeep  : int;
    }
end

(* Sensitivity *)

module QuadratureTypes = struct
  type 'a quadrhsfn = float -> 'a -> 'a -> 'a -> unit
end

module SensitivityTypes = struct
  type 'd sensresfn_args =
    {
      t : float;
      y : 'd;
      y' : 'd;
      res : 'd;
      s : 'd array;
      s' : 'd array;
      tmp : 'd triple
    }

  type 'd sensresfn = 'd sensresfn_args -> 'd array -> unit

  module QuadratureTypes = struct
    type 'd quadsensrhsfn =
      'd quadsensrhsfn_args
      -> 'd array
      -> unit

    and 'd quadsensrhsfn_args =
      {
        t : float;
        y : 'd;
        y' : 'd;
        s : 'd array;
        s' : 'd array;
        q : 'd;
        tmp : 'd triple;
      }
  end
end

module AdjointTypes' = struct
  type 'd bresfn_args =
    {
      t : float;
      y : 'd;
      y' : 'd;
      yb : 'd;
      yb' : 'd;
    }
  type 'a bresfn_no_sens = 'a bresfn_args -> 'a -> unit
  and 'a bresfn_with_sens = 'a bresfn_args -> 'a array -> 'a array -> 'a -> unit

  type 'a bresfn =
      NoSens of 'a bresfn_no_sens
    | WithSens of 'a bresfn_with_sens

  module QuadratureTypes = struct
    type 'd bquadrhsfn_args =
      {
        t : float;
        y : 'd;
        y' : 'd;
        yb : 'd;
        yb' : 'd;
      }

    type 'a bquadrhsfn =
        NoSens of 'a bquadrhsfn_no_sens
      | WithSens of 'a bquadrhsfn_with_sens

    and 'a bquadrhsfn_no_sens = 'a bquadrhsfn_args -> 'a -> unit
    and 'a bquadrhsfn_with_sens = 'a bquadrhsfn_args -> 'a array -> 'a array ->
                                  'a -> unit
  end

  type ('t, 'a) jacobian_arg =
    {
      jac_t   : float;
      jac_y   : 'a;
      jac_y'  : 'a;
      jac_yb  : 'a;
      jac_yb' : 'a;
      jac_resb : 'a;
      jac_coef : float;
      jac_tmp : 't
    }

  (* This is NOT the same as DlsTypes defined above.  This version
     refers to a different jacobian_arg, the one that was just
     defined.  *)

  module DirectTypes = struct

    type 'm jac_fn_no_sens =
      (RealArray.t triple, RealArray.t) jacobian_arg
      -> 'm
      -> unit

    type 'm jac_fn_with_sens =
      (RealArray.t triple, RealArray.t) jacobian_arg
      -> RealArray.t array
      -> RealArray.t array
      -> 'm
      -> unit

    type 'm jac_fn =
      NoSens of 'm jac_fn_no_sens
    | WithSens of 'm jac_fn_with_sens

    (* These fields are accessed from cvode_ml.c *)
    type 'm jac_callback_no_sens =
      {
        jacfn: 'm jac_fn_no_sens;
        mutable jmat : 'm option
      }

    let no_callback = fun _ _ -> Sundials_impl.crash "no direct callback"

    (* These fields are accessed from cvode_ml.c *)
    type 'm jac_callback_with_sens =
      {
        jacfn_sens: 'm jac_fn_with_sens;
        mutable jmat : 'm option
      }

  end

  (* Ditto. *)
  module SpilsTypes' = struct

    type 'a prec_solve_fn =
      (unit, 'a) jacobian_arg
      -> 'a
      -> 'a
      -> float
      -> unit

    type 'a prec_setup_fn = (unit, 'a) jacobian_arg -> unit

    type 'a precfns_no_sens =
      {
        prec_solve_fn : 'a prec_solve_fn;
        prec_setup_fn : 'a prec_setup_fn option;
      }

    type 'd jac_times_setup_fn_no_sens = (unit, 'd) jacobian_arg -> unit

    type 'a jac_times_vec_fn_no_sens =
      ('a, 'a) jacobian_arg
      -> 'a
      -> 'a
      -> unit

    (* versions with forward sensitivities *)

    type 'd prec_solve_fn_with_sens =
      (unit, 'd) jacobian_arg
      -> 'd array
      -> 'd array
      -> 'd
      -> 'd
      -> float
      -> unit

    type 'd prec_setup_fn_with_sens =
      (unit, 'd) jacobian_arg
      -> 'd array
      -> 'd array
      -> unit

    type 'a precfns_with_sens =
      {
        prec_solve_fn_sens : 'a prec_solve_fn_with_sens;
        prec_setup_fn_sens : 'a prec_setup_fn_with_sens option;
      }

    type 'd jac_times_setup_fn_with_sens =
      (unit, 'd) jacobian_arg -> 'd array -> unit

    type 'd jac_times_vec_fn_with_sens =
      ('d, 'd) jacobian_arg
      -> 'd array
      -> 'd array
      -> 'd
      -> 'd
      -> unit

  end
end

module IdasBbdParamTypes = struct
  type 'a local_fn = 'a AdjointTypes'.bresfn_args -> 'a -> unit
  type 'a comm_fn = 'a AdjointTypes'.bresfn_args -> unit
  type 'a precfns =
    {
      local_fn : 'a local_fn;
      comm_fn  : 'a comm_fn option;
    }
end
module IdasBbdTypes = IdaBbdTypes

type ida_mem
type c_weak_ref

type 'a resfn = float -> 'a -> 'a -> 'a -> unit
type 'a rootsfn = float -> 'a -> 'a -> RealArray.t -> unit
type error_handler = Util.error_details -> unit
type 'a error_weight_fun = 'a -> 'a -> unit

(* Session: here comes the big blob.  These mutually recursive types
   cannot be handed out separately to modules without menial
   repetition, so we'll just have them all here, at the top of the
   Types module.

   The ls_solver field only exists to ensure that the linear solver is not
   garbage collected while still being used by a session.
*)

(* Fields must be given in the same order as in cvode_session_index *)
type ('a,'kind) session = {
  ida        : ida_mem;
  backref    : c_weak_ref;
  nroots     : int;
  checkvec   : (('a, 'kind) Nvector.t -> unit);

  (* Temporary storage for exceptions raised within callbacks.  *)
  mutable exn_temp   : exn option;
  (* Tracks whether IDASetId has been called. *)
  mutable id_set     : bool;

  mutable resfn      : 'a resfn;
  mutable rootsfn    : 'a rootsfn;
  mutable errh       : error_handler;
  mutable errw       : 'a error_weight_fun;

  mutable ls_solver    : LSI.held_linear_solver;
  mutable ls_callbacks : ('a, 'kind) linsolv_callbacks;
  mutable ls_precfns   : 'a linsolv_precfns;

  mutable nls_solver   : ('a, 'kind, ('a, 'kind) session, [`Nvec])
                           NLSI.nonlinear_solver option;
  mutable nls_resfn    : 'a resfn;

  mutable sensext      : ('a, 'kind) sensext; (* Used by IDAS *)
}

and ('a, 'kind) sensext =
    NoSensExt
  | FwdSensExt of ('a, 'kind) fsensext
  | BwdSensExt of ('a, 'kind) bsensext

and ('a, 'kind) fsensext = {
  (* Quadrature *)
  mutable quadrhsfn       : 'a QuadratureTypes.quadrhsfn;
  mutable checkquadvec    : (('a, 'kind) Nvector.t -> unit);
  mutable has_quad        : bool;

  (* Sensitivity *)
  mutable num_sensitivities : int;
  mutable sensarray1        : 'a array;
  mutable sensarray2        : 'a array;
  mutable sensarray3        : 'a array;
  mutable senspvals         : RealArray.t option;
  (* keep a reference to prevent garbage collection *)

  mutable sensresfn         : 'a SensitivityTypes.sensresfn;

  mutable quadsensrhsfn     : 'a SensitivityTypes.QuadratureTypes.quadsensrhsfn;

  mutable fnls_solver       : ('a, 'kind, ('a, 'kind) session, [`Sens])
                                 NLSI.nonlinear_solver option;
  (* keep a reference to prevent garbage collection *)

  (* Adjoint *)
  mutable bsessions         : ('a, 'kind) session list;
  (* hold references to prevent garbage collection
     of backward sessions which are needed for
     callbacks. *)
}

and ('a, 'kind) bsensext = {
  (* Adjoint *)
  parent                : ('a, 'kind) session ;
  which                 : int;

  (* FIXME: extract num_sensitivities from bsensarray1 *)
  bnum_sensitivities    : int;
  bsensarray1           : 'a array;
  bsensarray2           : 'a array;

  mutable bresfn          : 'a AdjointTypes'.bresfn_no_sens;
  mutable bresfn_sens     : 'a AdjointTypes'.bresfn_with_sens;
  mutable bquadrhsfn      : 'a AdjointTypes'.QuadratureTypes.bquadrhsfn_no_sens;
  mutable bquadrhsfn_sens : 'a AdjointTypes'.QuadratureTypes.bquadrhsfn_with_sens;
  mutable checkbquadvec   : (('a, 'kind) Nvector.t -> unit);
}

(* Note: When compatibility with Sundials < 3.0.0 is no longer required,
         this type can be greatly simplified since we would no longer
         need to distinguish between different "direct" linear solvers.

   Note: The first field must always hold the callback closure
         (it is accessed as Field(cb, 0) from cvode_ml.c.
*)
and ('a, 'kind) linsolv_callbacks =
  | NoCallbacks

  (* Dls *)
  | DlsDenseCallback
      of Matrix.Dense.t DirectTypes.jac_callback
  | DlsBandCallback
      of Matrix.Band.t  DirectTypes.jac_callback

  | BDlsDenseCallback
      of Matrix.Dense.t AdjointTypes'.DirectTypes.jac_callback_no_sens
  | BDlsDenseCallbackSens
      of Matrix.Dense.t AdjointTypes'.DirectTypes.jac_callback_with_sens
  | BDlsBandCallback
      of Matrix.Band.t AdjointTypes'.DirectTypes.jac_callback_no_sens
  | BDlsBandCallbackSens
      of Matrix.Band.t AdjointTypes'.DirectTypes.jac_callback_with_sens

  (* Sls *)
  | SlsKluCallback
      : ('s Matrix.Sparse.t) DirectTypes.jac_callback
        -> ('a, 'kind) linsolv_callbacks
  | BSlsKluCallback
      : ('s Matrix.Sparse.t) AdjointTypes'.DirectTypes.jac_callback_no_sens
        -> ('a, 'kind) linsolv_callbacks
  | BSlsKluCallbackSens
      : ('s Matrix.Sparse.t) AdjointTypes'.DirectTypes.jac_callback_with_sens
        -> ('a, 'kind) linsolv_callbacks

  | SlsSuperlumtCallback
      : ('s Matrix.Sparse.t) DirectTypes.jac_callback
        -> ('a, 'kind) linsolv_callbacks
  | BSlsSuperlumtCallback
      : ('s Matrix.Sparse.t) AdjointTypes'.DirectTypes.jac_callback_no_sens
        -> ('a, 'kind) linsolv_callbacks
  | BSlsSuperlumtCallbackSens
      : ('s Matrix.Sparse.t) AdjointTypes'.DirectTypes.jac_callback_with_sens
        -> ('a, 'kind) linsolv_callbacks

  (* Custom *)
  | DirectCustomCallback :
      'm DirectTypes.jac_callback -> ('a, 'kind) linsolv_callbacks
  | BDirectCustomCallback :
      'm AdjointTypes'.DirectTypes.jac_callback_no_sens
      -> ('a, 'kind) linsolv_callbacks
  | BDirectCustomCallbackSens :
      'm AdjointTypes'.DirectTypes.jac_callback_with_sens
      -> ('a, 'kind) linsolv_callbacks

  (* Spils *)
  | SpilsCallback1 of 'a SpilsTypes'.jac_times_vec_fn option
                      * 'a SpilsTypes'.jac_times_setup_fn option
  | SpilsCallback2 of 'a resfn
  | BSpilsCallback
      of 'a AdjointTypes'.SpilsTypes'.jac_times_vec_fn_no_sens option
         * 'a AdjointTypes'.SpilsTypes'.jac_times_setup_fn_no_sens option
  | BSpilsCallbackSens
      of 'a AdjointTypes'.SpilsTypes'.jac_times_vec_fn_with_sens option
         * 'a AdjointTypes'.SpilsTypes'.jac_times_setup_fn_with_sens option
  | BSpilsCallbackJTRhsfn of 'a resfn

and 'a linsolv_precfns =
  | NoPrecFns

  | PrecFns of 'a SpilsTypes'.precfns
  | BPrecFns of 'a AdjointTypes'.SpilsTypes'.precfns_no_sens
  | BPrecFnsSens of 'a AdjointTypes'.SpilsTypes'.precfns_with_sens

  | BandedPrecFns

  | BBDPrecFns of 'a IdaBbdParamTypes.precfns
  | BBBDPrecFns of 'a IdasBbdParamTypes.precfns

(* Reverse lookup of a session value for a child session, given the pointer
   to the Sundials (child) session. *)
let revlookup_bsession ({ sensext; _ } : ('d, 'k) session) (child : ida_mem) =
  match sensext with
  | FwdSensExt { bsessions } ->
      List.find_opt (fun { ida; _ } -> ida = child) bsessions
  | NoSensExt | BwdSensExt _ -> None

(* called from sunml_cvodes_bsession_to_value *)
let _ = Callback.register "Idas.revlookup_bsession" revlookup_bsession


(* Linear solver check functions *)

let ls_check_direct session =
  if Sundials_configuration.safe then
    match session.ls_callbacks with
    | DlsDenseCallback _ | DlsBandCallback _
    | BDlsDenseCallback _ | BDlsDenseCallbackSens _
    | BDlsBandCallback _ | BDlsBandCallbackSens _
    | SlsKluCallback _ | BSlsKluCallback _ | BSlsKluCallbackSens _
    | SlsSuperlumtCallback _ | BSlsSuperlumtCallback _
    | BSlsSuperlumtCallbackSens _ | DirectCustomCallback _ -> ()
    | _ -> raise LinearSolver.InvalidLinearSolver

let ls_check_spils session =
  if Sundials_configuration.safe then
    match session.ls_callbacks with
    | SpilsCallback1 _ | SpilsCallback2 _
    | BSpilsCallback _ | BSpilsCallbackSens _ -> ()
    | _ -> raise LinearSolver.InvalidLinearSolver

let ls_check_spils_bbd session =
  if Sundials_configuration.safe then
    match session.ls_precfns with
    | BBDPrecFns _ | BBBDPrecFns _ -> ()
    | _ -> raise LinearSolver.InvalidLinearSolver

(* Types that depend on session *)

type 'kind serial_session = (Nvector_serial.data, 'kind) session
                            constraint 'kind = [>Nvector_serial.kind]

type ('data, 'kind) linear_solver =
  ('data, 'kind) session
  -> ('data, 'kind) Nvector.t (* y *)
  -> unit

type 'kind serial_linear_solver =
  (Nvector_serial.data, 'kind) linear_solver
  constraint 'kind = [>Nvector_serial.kind]

module SpilsTypes = struct
  include SpilsTypes'

  type ('a, 'k) set_preconditioner =
    ('a, 'k) session -> ('a, 'k) Nvector.t -> unit

  (* IDA(S) supports only left preconditioning.  *)
  type ('a, 'k) preconditioner =
    LSI.Iterative.preconditioning_type * ('a, 'k) set_preconditioner

  type 'k serial_preconditioner = (Nvector_serial.data, 'k) preconditioner
                                  constraint 'k = [>Nvector_serial.kind]

end

module AdjointTypes = struct
  include AdjointTypes'
  (* Backwards session. *)
  type ('a, 'k) bsession = Bsession of ('a, 'k) session
  type 'k serial_bsession = (Nvector_serial.data, 'k) bsession
                            constraint 'k = [>Nvector_serial.kind]
  let tosession (Bsession s) = s
  let parent_and_which s =
    match (tosession s).sensext with
    | BwdSensExt se -> (se.parent, se.which)
    | _ -> failwith "Internal error: bsession invalid"

  type ('data, 'kind) linear_solver =
    ('data, 'kind) bsession
    -> ('data, 'kind) Nvector.t (* y *)
    -> unit
  type 'kind serial_linear_solver =
    (Nvector_serial.data, 'kind) linear_solver
    constraint 'kind = [>Nvector_serial.kind]

  module SpilsTypes = struct
    include SpilsTypes'

    type ('a, 'k) set_preconditioner =
      ('a, 'k) bsession
      -> ('a, 'k) session
      -> int
      -> ('a, 'k) Nvector.t
      -> unit

    (* IDA(S) supports only left preconditioning.  *)
    type ('a, 'k) preconditioner =
      LSI.Iterative.preconditioning_type * ('a, 'k) set_preconditioner

    type 'k serial_preconditioner = (Nvector_serial.data, 'k) preconditioner
                                    constraint 'k = [>Nvector_serial.kind]

  end
end

let read_weak_ref x : ('a, 'kind) session =
  match Weak.get x 0 with
  | Some y -> y
  | None -> raise (Failure "Internal error: weak reference is dead")

let dummy_resfn _ _ _ _ =
  Sundials_impl.crash "Internal error: dummy_resfn called\n"
let dummy_nlsresfn _ _ _ _ =
  Sundials_impl.crash "Internal error: dummy_nlsresfn called\n"
let dummy_rootsfn _ _ _ _ =
  Sundials_impl.crash "Internal error: dummy_rootsfn called\n"
let dummy_errh _ =
  Sundials_impl.crash "Internal error: dummy_errh called\n"
let dummy_errw _ _ =
  Sundials_impl.crash "Internal error: dummy_errw called\n"
let dummy_bresfn_no_sens _ _ =
  Sundials_impl.crash "Internal error: dummy_bresfn_no_sens called\n"
let dummy_bresfn_with_sens _ _ _ _ =
  Sundials_impl.crash "Internal error: dummy_bresfn_with_sens called\n"
let dummy_bquadrhsfn_no_sens _ _ =
  Sundials_impl.crash "Internal error: dummy_bquadrhsfn_no_sens called\n"
let dummy_bquadrhsfn_with_sens _ _ _ _ =
  Sundials_impl.crash "Internal error: dummy_bquadrhsfn_with_sens called\n"
let dummy_quadrhsfn _ _ _ _ =
  Sundials_impl.crash "Internal error: dummy_quadrhsfn called\n"
let dummy_sensresfn _ _ =
  Sundials_impl.crash "Internal error: dummy_sensresfn called\n"
let dummy_quadsensrhsfn _ _ =
  Sundials_impl.crash "Internal error: dummy_quadsensrhsfn called\n"
