(*
 * -----------------------------------------------------------------
 * $Revision: 1.2 $
 * $Date: 2009/09/30 23:25:59 $
 * -----------------------------------------------------------------
 * Programmer(s): Allan Taylor, Alan Hindmarsh and
 *                Radu Serban @ LLNL
 * -----------------------------------------------------------------
 * OCaml port: Jun Inoue, Inria, Aug 2014.
 * -----------------------------------------------------------------
 * Example problem for IDA: 2D heat equation, serial, GMRES.
 *
 * This example solves a discretized 2D heat equation problem.
 * This version uses the Krylov solver IDASpgmr.
 *
 * The DAE system solved is a spatial discretization of the PDE
 *          du/dt = d^2u/dx^2 + d^2u/dy^2
 * on the unit square. The boundary condition is u = 0 on all edges.
 * Initial conditions are given by u = 16 x (1 - x) y (1 - y). The
 * PDE is treated with central differences on a uniform M x M grid.
 * The values of u at the interior points satisfy ODEs, and
 * equations u = 0 at the boundaries are appended, to form a DAE
 * system of size N = M^2. Here M = 10.
 *
 * The system is solved with IDA using the Krylov linear solver
 * IDASPGMR. The preconditioner uses the diagonal elements of the
 * Jacobian only. Routines for preconditioning, required by
 * IDASPGMR, are supplied here. The constraints u >= 0 are posed
 * for all components. Output is taken at t = 0, .01, .02, .04,
 * ..., 10.24. Two cases are run -- with the Gram-Schmidt type
 * being Modified in the first case, and Classical in the second.
 * The second run uses IDAReInit and IDAReInitSpgmr.
 * -----------------------------------------------------------------
 *)

open Sundials

let lt600 =
  let n, _, _ = Config.sundials_version in
  n < 6

(* Problem Constants *)
let nout  = 11
let mgrid = 10
let neq   = mgrid*mgrid

(* Shorthands *)
let nvscale = Nvector_serial.DataOps.scale
let nvprod = Nvector_serial.DataOps.prod
let nvmaxnorm = Nvector_serial.DataOps.maxnorm
let printf = Printf.printf

(* User data *)
type user_data =
  {
    mm    : int;                        (* number of grid points *)
    dx    : float;
    coeff : float;
    pp    : RealArray.t;          (* vector of prec. diag. elements *)
  }

(*
 * resHeat: heat equation system residual function (user-supplied)
 * This uses 5-point central differencing on the interior points, and
 * includes algebraic equations for the boundary values.
 * So for each interior point, the residual component has the form
 *    res_i = u'_i - (central difference)_i
 * while for each boundary point, it is res_i = u_i.
 *)
let res_heat data _ (u : RealArray.t) (u' : RealArray.t) r =
  let coeff = data.coeff
  and mm    = data.mm in

  (* Initialize r to u, to take care of boundary equations. *)
  RealArray.blit ~src:u ~dst:r;

  (* Loop over interior points; set res = up - (central difference).  *)
  for j = 1 to mgrid-2 do
    let offset = mm*j in
    for i = 1 to mm-2 do
      let loc = offset + i in
      let dif1 = u.{loc-1} +. u.{loc+1} -. 2. *. u.{loc}
      and dif2 = u.{loc-mm} +. u.{loc+mm} -. 2. *. u.{loc} in
      r.{loc} <- u'.{loc} -. coeff *. (dif1 +. dif2)
    done
  done

(*
 * p_setup_heat: setup for diagonal preconditioner for idaHeat2D_kry.
 *
 * The optional user-supplied functions p_setup_heat and
 * p_solve_heat together must define the left preconditoner
 * matrix P approximating the system Jacobian matrix
 *                   J = dF/du + cj*dF/du'
 * (where the DAE system is F(t,u,u') = 0), and solve the linear
 * systems P z = r.   This is done in this case by keeping only
 * the diagonal elements of the J matrix above, storing them as
 * inverses in a vector pp, when computed in p_setup_heat, for
 * subsequent use in p_solve_heat.
 *
 * In this instance, only cj and data (user data structure, with
 * pp etc.) are used from the p_setup_heat argument list.
 *)
let p_setup_heat data jac =
  let pp = data.pp
  and mm = data.mm
  and c_j = jac.Ida.jac_coef
  in

  (* Initialize the entire vector to 1., then set the interior points to the
     correct value for preconditioning. *)
  RealArray.fill pp 1.;

  (* Compute the inverse of the preconditioner diagonal elements. *)
  let pelinv = 1. /. (c_j +. 4.*.data.coeff) in

  for j = 1 to mm-2 do
    let offset = mm*j in
    for i = 1 to mm-2 do
      let loc = offset + i in
      pp.{loc} <- pelinv
    done
  done

(*
 * p_solve_heat: solve preconditioner linear system.
 * This routine multiplies the input vector rvec by the vector pp
 * containing the inverse diagonal Jacobian elements (previously
 * computed in PrecondHeateq), returning the result in zvec.
 *)
let p_solve_heat data _ rvec zvec _ =
  nvprod data.pp rvec zvec

(*
 * set_initial_profile: routine to initialize u and u' vectors.
 *)

let set_initial_profile data u u' res =
  let mm = data.mm in

  (* Initialize uu on all grid points. *)
  let mm1 = mm - 1 in
  for j = 0 to mm-1 do
    let yfact = data.dx *. float_of_int j
    and offset = mm*j in
    for i = 0 to mm-1 do
      let xfact = data.dx *. float_of_int i
      and loc = offset + i in
      u.{loc} <- 16.0 *. xfact *. (1. -. xfact) *. yfact *. (1. -. yfact)
    done
  done;

  (* Initialize up vector to 0. *)
  RealArray.fill u' 0.;

  (* res_heat sets res to negative of ODE RHS values at interior points. *)
  res_heat data 0. u u' res;

  (* Copy -res into up to get correct interior initial up values. *)
  nvscale (-1.) res u';

  (* Set up at boundary points to zero. *)
  for j = 0 to mm-1 do
    let offset = mm*j in
    for i = 0 to mm-1 do
      let loc = offset + i in
      if j = 0 || j = mm1 || i = 0 || i = mm1 then
        u'.{loc} <- 0.
    done
  done

let idaspgmr =
  match Config.sundials_version with 2,_,_ -> "IDASPGMR" | _ -> "SPGMR"

(*
 * Print first lines of output (problem description)
 *)
let print_header rtol atol =
  printf "\nidaHeat2D_kry: Heat equation, serial example problem for IDA \n";
  printf "         Discretized heat equation on 2D unit square. \n";
  printf "         Zero boundary conditions,";
  printf " polynomial initial conditions.\n";
  printf "         Mesh dimensions: %d x %d" mgrid mgrid;
  printf "        Total system size: %d\n\n" neq;
  printf "Tolerance parameters:  rtol = %g   atol = %g\n" rtol atol;
  printf "Constraints set to force all solution components >= 0. \n";
  printf "Linear solver: %s, preconditioner using diagonal elements. \n" idaspgmr

(*
 * print_output: print max norm of solution and current solver statistics
 *)
let print_output mem t u =
  let open Ida in
  let umax = nvmaxnorm u;
  and kused = get_last_order mem
  and nst   = get_num_steps mem
  and nni   = get_num_nonlin_solv_iters mem
  and nre   = get_num_res_evals mem
  and hused = get_last_step mem
  and nje   = Spils.get_num_jtimes_evals mem
  and nreLS = Spils.get_num_lin_res_evals mem
  and npe   = Spils.get_num_prec_evals mem
  and nps   = Spils.get_num_prec_solves mem in
  printf " %5.2f %13.5e  %d  %3d  %3d  %3d  %4d  %4d  %9.2e  %3d %3d\n"
         t umax kused nst nni nje nre nreLS hused npe nps


let main () =
  (* Allocate N-vectors and the user data structure. *)
  let u = RealArray.create neq
  and u' = RealArray.create neq
  and res = RealArray.create neq
  and constraints = RealArray.create neq in

  let dx = 1. /. float_of_int (mgrid - 1) in
  let data = { pp = RealArray.create neq;
               mm = mgrid;
               dx = dx;
               coeff = 1. /. (dx *. dx);
             }
  in

  (* Initialize u, u'. *)
  set_initial_profile data u u' res;

  (* Set constraints to all non-negative. *)
  RealArray.fill constraints Constraint.geq_zero;

  (* Assign various parameters. *)

  let t0   = 0.0
  and t1   = 0.01
  and rtol = 0.0
  and atol = 1.0e-3 in

  (* Wrap u and u' in nvectors.  Operations performed on the wrapped
     representation affect the originals u and u'.  *)
  let wu = Nvector_serial.wrap u
  and wu' = Nvector_serial.wrap u'
  in

  (* Call IDACreate to initialize solution with SPGMR linear solver.  *)

  let lsolver = Ida.Spils.(spgmr ~maxl:5 wu) in
  let mem = Ida.(init
                  (SStolerances (rtol, atol))
                  ~lsolver:Spils.(solver lsolver
                                         (prec_left ~setup:(p_setup_heat data)
                                                           (p_solve_heat data)))
                  (res_heat data) t0 wu wu') in
  Ida.set_constraints mem (Nvector_serial.wrap constraints);

  (* Print output heading. *)
  print_header rtol atol;

  (*
   * -------------------------------------------------------------------------
   * CASE I
   * -------------------------------------------------------------------------
   *)

  (* Print case number, output table heading, and initial line of table. *)

  if lt600
  then printf "\n\nCase 1: gsytpe = MODIFIED_GS\n"
  else printf "\n\nCase 1: gsytpe = SUN_MODIFIED_GS\n";
  printf "\n   Output Summary (umax = max-norm of solution) \n\n";
  printf "  time     umax       k  nst  nni  nje   nre   nreLS    h      npe nps\n" ;
  printf "----------------------------------------------------------------------\n";

  (* Loop over output times, call IDASolve, and print results. *)

  let tout = ref t1 in
  for _ = 1 to nout do
    let tret, _ = Ida.solve_normal mem !tout wu wu' in
    print_output mem tret u;
    tout := !tout *. 2.
  done;

  (* Print remaining counters. *)

  let netf = Ida.get_num_err_test_fails mem
  and ncfn = Ida.get_num_nonlin_solv_conv_fails mem
  and ncfl = Ida.Spils.get_num_lin_conv_fails mem in
  printf "\nError test failures            = %d\n" netf;
  printf "Nonlinear convergence failures = %d\n" ncfn;
  printf "Linear convergence failures    = %d\n" ncfl;

  (*
   * -------------------------------------------------------------------------
   * CASE II
   * -------------------------------------------------------------------------
   *)

  (* Re-initialize u, u'. *)

  set_initial_profile data u u' res;

  (* Re-initialize IDA and IDASPGMR *)

  Ida.reinit mem t0 wu wu';
  Ida.Spils.(set_gs_type lsolver ClassicalGS);

  (* Print case number, output table heading, and initial line of table. *)
  if lt600
  then printf "\n\nCase 2: gstype = CLASSICAL_GS\n"
  else printf "\n\nCase 2: gstype = SUN_CLASSICAL_GS\n";
  printf "\n   Output Summary (umax = max-norm of solution) \n\n";
  printf "  time     umax       k  nst  nni  nje   nre   nreLS    h      npe nps\n" ;
  printf "----------------------------------------------------------------------\n";

  (* Loop over output times, call IDASolve, and print results. *)
  let tout = ref t1 in
  for _ = 1 to nout do
    let tret, _ = Ida.solve_normal mem !tout wu wu' in
    print_output mem tret u;
    tout := !tout *. 2.
  done;

  (* Print remaining counters. *)

  let netf = Ida.get_num_err_test_fails mem
  and ncfn = Ida.get_num_nonlin_solv_conv_fails mem
  and ncfl = Ida.Spils.get_num_lin_conv_fails mem in
  printf "\nError test failures            = %d\n" netf;
  printf "Nonlinear convergence failures = %d\n" ncfn;
  printf "Linear convergence failures    = %d\n" ncfl


(* Check environment variables for extra arguments.  *)
let reps =
  try int_of_string (Unix.getenv "NUM_REPS")
  with Not_found | Failure _ -> 1
let gc_at_end =
  try int_of_string (Unix.getenv "GC_AT_END") <> 0
  with Not_found | Failure _ -> false
let gc_each_rep =
  try int_of_string (Unix.getenv "GC_EACH_REP") <> 0
  with Not_found | Failure _ -> false

(* Entry point *)
let _ =
  for _ = 1 to reps do
    main ();
    if gc_each_rep then Gc.compact ()
  done;
  if gc_at_end then Gc.compact ()
