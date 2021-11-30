(*
 * -----------------------------------------------------------------
 * $Revision: 4455 $
 * $Date: 2015-03-28 18:28:53 -0700 (Sat, 28 Mar 2015) $
 * -----------------------------------------------------------------
 * Programmer(s): David J. Gardner @ LLNL
 * -----------------------------------------------------------------
 * LLNS Copyright Start
 * Copyright (c) 2014, Lawrence Livermore National Security
 * This work was performed under the auspices of the U.S. Department
 * of Energy by Lawrence Livermore National Laboratory in part under
 * Contract W-7405-Eng-48 and in part under Contract DE-AC52-07NA27344.
 * Produced at the Lawrence Livermore National Laboratory.
 * All rights reserved.
 * For details, see the LICENSE file.
 * LLNS Copyright End
 * -----------------------------------------------------------------
 * This is the testing routine to check the open MP NVECTOR module
 * implementation.
 * -----------------------------------------------------------------
 *)
module Nvector_openmp_ops : Test_nvector.NVECTOR_OPS_EXT
  with type t = Nvector_openmp.t
  =
struct
  include Nvector_openmp.Ops
  let get_id = Nvector.get_id
  type data = Sundials.RealArray.t
  let getarray = Nvector_openmp.unwrap
  let get = Sundials.RealArray.get
  let set = Sundials.RealArray.set
  let max_time x t = t
  let sync_device () = ()
end

module Test = Test_nvector.Test (Nvector_openmp_ops)

let printf = Printf.printf
let (+=) r x = r := !r + x

(* ----------------------------------------------------------------------
 * Main NVector Testing Routine
 * --------------------------------------------------------------------*)
let main () =
  let fails = ref 0 in

  (* check input and set vector length *)
  if Array.length Sys.argv < 4 then (
    printf "ERROR: THREE (3) arguments required: <vector length> <number of threads> <print timing>\n";
    exit (-1)
  );

  let length = int_of_string Sys.argv.(1) in
  if length <= 0 then (
    printf "ERROR: length of vector must be a positive integer \n";
    exit (-1);
  );

  let num_threads = int_of_string Sys.argv.(2) in
  if num_threads <= 0 then (
    printf "ERROR: numbber of threads must be a positive integer \n";
    exit (-1);
  );

  let print_timing = int_of_string Sys.argv.(3) in
  let _ = Test.set_timing (print_timing <> 0) true in

  if Test_nvector.compat_ge400
  then printf "Testing the OpenMP N_Vector \n\
               Vector length %d \n\
               Number of threads %d \n\n" length num_threads
  else printf "\nRunning with vector length %d \n \n\
               \nRunning with number of threads %d \n \n" length num_threads;

  (* Create vectors *)
  let w = Nvector_openmp.make num_threads length 0.0
  and x = Nvector_openmp.make num_threads length 0.0
  and y = Nvector_openmp.make num_threads length 0.0
  and z = Nvector_openmp.make num_threads length 0.0
  in

  (* NVector Tests *)
  if Test_nvector.compat_ge400 then begin
    fails += Test.test_getvectorid x Nvector.OpenMP 0;
    if Test_nvector.compat_ge500 then begin
      fails += Test.test_getlength x 0;
      fails += Test.test_getcommunicator x 0 0;
    end;
    fails += Test.test_cloneempty x 0;
    fails += Test.test_clone x length 0;
    fails += Test.test_cloneemptyvectorarray 5 x 0;
    fails += Test.test_clonevectorarray 5 x length 0
  end;
  fails += Test.test_setarraypointer w length 0;
  fails += Test.test_getarraypointer x length 0;
  if Test_nvector.compat_ge400 then begin
    printf "\nTesting standard vector operations:\n\n";
    fails += Test.test_const x length 0
  end;
  fails += Test.test_linearsum x y z length 0;
  if not Test_nvector.compat_ge400 then begin
    fails += Test.test_const x length 0;
  end;
  fails += Test.test_prod x y z length 0;
  fails += Test.test_div x y z length 0;
  fails += Test.test_scale x z length 0;
  fails += Test.test_abs x z length 0;
  fails += Test.test_inv x z length 0;
  fails += Test.test_addconst x z length 0;
  fails += Test.test_dotprod x y length length 0;
  fails += Test.test_maxnorm x length 0;
  fails += Test.test_wrmsnorm x y length 0;
  if Test_nvector.compat_ge400
  then fails += Test.test_wrmsnormmask x y z length length 0
  else fails += Test.test_wrmsnormmask_lt400 x y z length length 0;
  fails += Test.test_min x length 0;
  fails += Test.test_wl2norm x y length length 0;
  fails += Test.test_l1norm x length length 0;
  fails += Test.test_compare x z length 0;
  fails += Test.test_invtest x z length 0;
  fails += Test.test_constrmask x y z length 0;
  fails += Test.test_minquotient x y length 0;
  if not Test_nvector.compat_ge400 then begin
    fails += Test.test_clonevectorarray 5 x length 0;
    fails += Test.test_cloneemptyvectorarray 5 x 0;
    fails += Test.test_cloneempty x 0;
    fails += Test.test_clone x length 0;
  end;

  if Test_nvector.compat_ge400 then begin
    (* Fused and vector array operations tests (disabled) *)
    printf "\nTesting fused and vector array operations (disabled):\n\n";

    let u = Nvector_openmp.make ~with_fused_ops:false num_threads length 0.0 in

    (* fused operations *)
    fails += Test.test_linearcombination u length 0;
    fails += Test.test_scaleaddmulti u length 0;
    fails += Test.test_dotprodmulti u length length 0;

    (* vector array operations *)
    fails += Test.test_linearsumvectorarray u length 0;
    fails += Test.test_scalevectorarray u length 0;
    fails += Test.test_constvectorarray u length 0;
    fails += Test.test_wrmsnormvectorarray u length 0;
    fails += Test.test_wrmsnormmaskvectorarray u length length 0;
    fails += Test.test_scaleaddmultivectorarray u length 0;
    fails += Test.test_linearcombinationvectorarray u length 0
  end;

  if Test_nvector.compat_ge400 then begin
    (* Fused and vector array operations tests (enabled) *)
    printf "\nTesting fused and vector array operations (enabled):\n\n";

    let u = Nvector_openmp.make ~with_fused_ops:true num_threads length 0.0 in

    (* fused operations *)
    fails += Test.test_linearcombination u length 0;
    fails += Test.test_scaleaddmulti u length 0;
    fails += Test.test_dotprodmulti u length length 0;

    (* vector array operations *)
    fails += Test.test_linearsumvectorarray u length 0;
    fails += Test.test_scalevectorarray u length 0;
    fails += Test.test_constvectorarray u length 0;
    fails += Test.test_wrmsnormvectorarray u length 0;
    fails += Test.test_wrmsnormmaskvectorarray u length length 0;
    fails += Test.test_scaleaddmultivectorarray u length 0;
    fails += Test.test_linearcombinationvectorarray u length 0
  end;

  (* local reduction operations *)
  if Test_nvector.compat_ge500 then begin
    printf "\nTesting local reduction operations:\n\n";

    fails += Test.test_dotprodlocal x y length 0;
    fails += Test.test_maxnormlocal x length 0;
    fails += Test.test_minlocal x length 0;
    fails += Test.test_l1normlocal x length 0;
    fails += Test.test_wsqrsumlocal x y length 0;
    fails += Test.test_wsqrsummasklocal x y z length 0;
    fails += Test.test_invtestlocal x z length 0;
    fails += Test.test_constrmasklocal x y z length 0;
    fails += Test.test_minquotientlocal x y length 0
  end;

  (* XBraid interface operations *)
  if Test_nvector.compat_ge540 then begin
    printf "\nTesting XBraid interface operations:\n\n";

    fails += Test.test_bufsize x length 0;
    fails += Test.test_bufpack x length 0;
    fails += Test.test_bufunpack x length 0
  end;

  (* Free vectors *)

  (* Print results *)
  if !fails <> 0 then
    printf "FAIL: NVector module failed %d tests \n%s\n" !fails
      (if Test_nvector.compat_ge400 then "" else " ")
  else
    printf "SUCCESS: NVector module passed all tests \n%s\n"
      (if Test_nvector.compat_ge400 then "" else " ")

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
  for i = 1 to reps do
    main ();
    if gc_each_rep then Gc.compact ()
  done;
  if gc_at_end then Gc.compact ()
