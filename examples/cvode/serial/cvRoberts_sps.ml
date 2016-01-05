(*
 * -----------------------------------------------------------------
 * $Revision: 4182 $
 * $Date: 2014-07-23 13:05:06 -0700 (Wed, 23 Jul 2014) $
 * -----------------------------------------------------------------
 * Programmer(s): Carol Woodward.
 *      Based on cvRoberts_dns.c and modified to use SUPERLU_MT.
 * -----------------------------------------------------------------
 * OCaml port: Timothy Bourke, Inria, Dec 2015.
 * -----------------------------------------------------------------
 * Example problem:
 * 
 * The following is a simple example problem, with the coding
 * needed for its solution by CVODE. The problem is from
 * chemical kinetics, and consists of the following three rate
 * equations:         
 *    dy1/dt = -.04*y1 + 1.e4*y2*y3
 *    dy2/dt = .04*y1 - 1.e4*y2*y3 - 3.e7*(y2)^2
 *    dy3/dt = 3.e7*(y2)^2
 * on the interval from t = 0.0 to t = 4.e10, with initial
 * conditions: y1 = 1.0, y2 = y3 = 0. The problem is stiff.
 * While integrating the system, we also use the rootfinding
 * feature to find the points at which y1 = 1e-4 or at which
 * y3 = 0.01. This program solves the problem with the BDF method,
 * Newton iteration with the CVSUPERLUMT sparse direct linear solver, and a
 * user-supplied Jacobian routine.
 * It uses a scalar relative tolerance and a vector absolute
 * tolerance. Output is printed in decades from t = .4 to t = 4.e10.
 * Run statistics (optional outputs) are printed at the end.
 * -----------------------------------------------------------------
 *)

module RealArray = Sundials.RealArray
module Roots = Sundials.Roots
let unwrap = Nvector.unwrap

let printf = Printf.printf

let ith (v : RealArray.t) i = v.{i - 1}
let set_ith (v : RealArray.t) i e = v.{i - 1} <- e

(* Problem Constants *)

let neq    = 3        (* number of equations  *)
let y1     = 1.0      (* initial y components *)
let y2     = 0.0
let y3     = 0.0
let rtol   = 1.0e-4   (* scalar relative tolerance            *)
let atol1  = 1.0e-8   (* vector absolute tolerance components *)
let atol2  = 1.0e-14
let atol3  = 1.0e-6
let t0     = 0.0      (* initial time           *)
let t1     = 0.4      (* first output time      *)
let tmult  = 10.0     (* output time factor     *)
let nout   = 12       (* number of output times *)
let nroots = 2        (* number of root functions *)

let f t (y : RealArray.t) (yd : RealArray.t) =
  let yd1 = -0.04 *. y.{0} +. 1.0e4 *. y.{1} *. y.{2}
  and yd3 = 3.0e7 *. y.{1} *. y.{1}
  in
  yd.{0} <- yd1;
  yd.{1} <- (-. yd1 -. yd3);
  yd.{2} <- yd3

let g t (y : RealArray.t) (gout : RealArray.t) =
  gout.{0} <- y.{0} -. 0.0001;
  gout.{1} <- y.{2} -. 0.01

let jac {Cvode.jac_y = (y : RealArray.t)} smat =
  let set_col = Sls.SparseMatrix.set_col smat in
  let set = Sls.SparseMatrix.set smat in
  set_col 0 0;
  set_col 1 3;
  set_col 2 6;
  set_col 3 9;

  set 0 0 (-0.04);
  set 1 1  0.04;
  set 2 2  0.00;

  set 3 0 (1.0e4 *. y.{2});
  set 4 1 (-1.0e4 *. y.{2} -. 6.0e7 *. y.{1});
  set 5 2 (6.0e7 *. y.{1});

  set 6 0 (1.0e4 *. y.{1});
  set 7 1 (-1.0e4 *. y.{1});
  set 8 2 0.00
  
let print_output =
  printf "At t = %0.4e      y =%14.6e  %14.6e  %14.6e\n"

let print_root_info r1 r2 =
  printf "    rootsfound[] = %3d %3d\n"
    (Roots.int_of_root r1)
    (Roots.int_of_root r2)

let print_final_stats s =
  let open Cvode in
  let nst     = get_num_steps s
  and nfe     = get_num_rhs_evals s
  and nsetups = get_num_lin_solv_setups s
  and netf    = get_num_err_test_fails s
  and nni     = get_num_nonlin_solv_iters s
  and ncfn    = get_num_nonlin_solv_conv_fails s
  and nje     = Cvode_superlumt.get_num_jac_evals s
  and nge     = get_num_g_evals s
  in
  printf "\nFinal Statistics:\n";
  printf "nst = %-6d nfe  = %-6d nsetups = %-6d nje = %d\n"
    nst nfe nsetups nje;
  printf "nni = %-6d ncfn = %-6d netf = %-6d nge = %d\n \n"
    nni ncfn netf nge

let main () =
  (* Create serial vector of length NEQ for I.C. and abstol *)
  let y = Nvector_serial.make neq 0.0
  and abstol = RealArray.create neq
  and roots = Roots.create nroots
  and nnz = neq * neq
  in
  let ydata = unwrap y in
  let r = Roots.get roots in

  (* Initialize y *)
  set_ith ydata 1 y1;
  set_ith ydata 2 y2;
  set_ith ydata 3 y3;

  (* Set the vector absolute tolerance *)
  set_ith abstol 1 atol1;
  set_ith abstol 2 atol2;
  set_ith abstol 3 atol3;

  printf " \n3-species kinetics problem\n\n";

  (* Call CVodeCreate to create the solver memory and specify the 
   * Backward Differentiation Formula and the use of a Newton iteration *)
  (* Call CVodeInit to initialize the integrator memory and specify the
   * user's right hand side function in y'=f(t,y), the inital time T0, and
   * the initial dependent variable vector y. *)
  (* Call CVodeRootInit to specify the root function g with 2 components *)
  (* Call CVDense to specify the CVDENSE dense linear solver *)
  (* Set the Jacobian routine to Jac (user-supplied) *)
  let cvode_mem =
    Cvode.(init BDF (Newton (Cvode_superlumt.superlumt jac ~nnz ~nthreads:1))
                (SVtolerances (rtol, (Nvector_serial.wrap abstol))) f
                ~roots:(nroots, g) t0 y)
  in

  (* In loop, call CVode, print results, and test for error.
     Break out of loop when NOUT preset output times have been reached.  *)

  let tout = ref t1
  and iout = ref 0
  in
  while (!iout <> nout) do

    let (t, flag) = Cvode.solve_normal cvode_mem !tout y
    in
    print_output t (ith ydata 1) (ith ydata 2) (ith ydata 3);

    match flag with
    | Cvode.RootsFound ->
        Cvode.get_root_info cvode_mem roots;
        print_root_info (r 0) (r 1)

    | Cvode.Success ->
        iout := !iout + 1;
        tout := !tout *. tmult

    | Cvode.StopTimeReached ->
        iout := nout
  done;

  (* Print some final statistics *)
  print_final_stats cvode_mem

(* Check environment variables for extra arguments.  *)
let reps =
  try int_of_string (Unix.getenv "NUM_REPS")
  with Not_found | Failure "int_of_string" -> 1
let gc_at_end =
  try int_of_string (Unix.getenv "GC_AT_END") <> 0
  with Not_found | Failure "int_of_string" -> false
let gc_each_rep =
  try int_of_string (Unix.getenv "GC_EACH_REP") <> 0
  with Not_found | Failure "int_of_string" -> false

(* Entry point *)
let _ =
  for i = 1 to reps do
    main ();
    if gc_each_rep then Gc.compact ()
  done;
  if gc_at_end then Gc.compact ()