(*-----------------------------------------------------------------
 * Programmer(s): Daniel R. Reynolds @ SMU
 *---------------------------------------------------------------
 * OCaml port: Timothy Bourke, Inria, Jan 2016.
 * --------------------------------------------------------------------
 * Copyright (c) 2015, Southern Methodist University and 
 * Lawrence Livermore National Security
 *
 * This work was performed under the auspices of the U.S. Department 
 * of Energy by Southern Methodist University and Lawrence Livermore 
 * National Laboratory under Contract DE-AC52-07NA27344.
 * Produced at Southern Methodist University and the Lawrence 
 * Livermore National Laboratory.
 *
 * All rights reserved.
 * For details, see the LICENSE file.
 *---------------------------------------------------------------
 * Demonstration program for ARKODE - Krylov linear solver.
 * ODE system from ns-species interaction PDE in 2 dimensions.
 * 
 * This program solves a stiff ODE system that arises from a system
 * of partial differential equations. The PDE system is a food web
 * population model, with predator-prey interaction and diffusion on
 * the unit square in two dimensions. The dependent variable vector is:
 *
 *        1   2        ns
 *  c = (c , c , ..., c  )
 *
 * and the PDEs are as follows:
 *
 *    i               i      i
 *  dc /dt  =  d(i)*(c    + c   )  +  f (x,y,c)  (i=1,...,ns)
 *                    xx     yy        i   
 *
 * where
 *
 *                 i          ns         j
 *  f (x,y,c)  =  c *(b(i) + sum a(i,j)*c )
 *   i                       j=1                                         
 *                                                                       
 * The number of species is ns = 2*np, with the first np being prey
 * and the last np being predators. The coefficients a(i,j), b(i),
 * d(i) are:
 *
 *  a(i,i) = -a  (all i)
 *  a(i,j) = -g  (i <= np, j > np)
 *  a(i,j) =  e  (i > np, j <= np)
 *  b(i) =  b*(1 + alpha*x*y)  (i <= np)
 *  b(i) = -b*(1 + alpha*x*y)  (i > np)
 *  d(i) = Dprey  (i <= np)
 *  d(i) = Dpred  (i > np)
 *
 * The spatial domain is the unit square. The final time is 10.
 * The boundary conditions are: normal derivative = 0.
 * A polynomial in x and y is used to set the initial conditions.
 *
 * The PDEs are discretized by central differencing on an MX by MY mesh.
 *
 * The resulting ODE system is stiff.
 *
 * The ODE system is solved using Newton iteration and the ARKSPGMR
 * linear solver (scaled preconditioned GMRES).
 *
 * The preconditioner matrix used is the product of two matrices:
 * (1) A matrix, only defined implicitly, based on a fixed number
 * of Gauss-Seidel iterations using the diffusion terms only.
 * (2) A block-diagonal matrix based on the partial derivatives
 * of the interaction terms f only, using block-grouping (computing
 * only a subset of the ns by ns blocks).
 *
 * Four different runs are made for this problem.
 * The product preconditoner is applied on the left and on the
 * right. In each case, both the modified and classical Gram-Schmidt
 * options are tested.
 * In the series of runs, ARKodeInit and ARKSpgmr are called only
 * for the first run, whereas ARKodeReInit, ARKSpilsSetPrecType and
 * ARKSpilsSetGSType are called for each of the remaining three runs.
 *
 * A problem description, performance statistics at selected output
 * times, and final statistics are written to standard output.
 * On the first run, solution values are also printed at output
 * times. Error and warning messages are written to standard error,
 * but there should be no such messages.
 *
 * Note: This program requires the dense linear solver functions
 * newDenseMat, newIntArray, denseAddIdentity, denseGETRF, denseGETRS, 
 * destroyMat and destroyArray.
 *
 * Note: This program assumes the sequential implementation for the
 * type N_Vector and uses the NV_DATA_S macro to gain access to the
 * contiguous array of components of an N_Vector.
 * -------------------------------------------------------------------
 * Reference: Peter N. Brown and Alan C. Hindmarsh, Reduced Storage
 * Matrix Methods in Stiff ODE Systems, J. Appl. Math. & Comp., 31
 * (1989), pp. 40-91.  Also available as Lawrence Livermore National
 * Laboratory Report UCRL-95088, Rev. 1, June 1987.
 * -------------------------------------------------------------------
 *)

module RealArray = Sundials.RealArray
module LintArray = Sundials.LintArray
module Roots = Sundials.Roots
module Densemat = Dls.ArrayDenseMatrix
open Bigarray
let unwrap = Nvector.unwrap

let printf = Printf.printf
let sqr x = x *. x

(* Constants *)

let zero  = 0.0
let one   = 1.0

(* Problem Specification Constants *)

let aa     = one       (* AA = a *)
let ee     = 1.0e4     (* EE = e *)
let gg     = 0.5e-6    (* GG = g *)
let bb     = one       (* BB = b *)
let dprey  = one
let dpred  = 0.5
let alph   = one
let np     = 3
let ns     = (2 * np)

(* Method Constants *)

let mx     = 6
let my     = 6
let mxns   = (mx * ns)
let ax     = one
let ay     = one
let dx     = (ax /. float (mx - 1))
let dy     = (ay /. float (my - 1))
let mp     = ns
let mq     = (mx * my)
let mxmp   = (mx * mp)
let ngx    = 2
let ngy    = 2
let ngrp   = (ngx * ngy)
let itmax  = 5

(* ARKodeInit Constants *)

let neq   = ns * mx * my
let t0    = zero
let rtol  = 1.0e-5
let atol  = 1.0e-5

(* ARKSpgmr Constants *)

let maxl  = 0     (* => use default = MIN(NEQ, 5)            *)
let delt  = zero  (* => use default = 0.05                   *)

(* Output Constants *)

let t1         = 1.0e-8
let tout_mult  = 10.0
let dtout      = one
let nout       = 18

(* Note: The value for species i at mesh point (j,k) is stored in *)
(* component number (i-1) + j*NS + k*NS*MX of an N_Vector,        *)
(* where 1 <= i <= NS, 0 <= j < MX, 0 <= k < MY.                  *)

(* Structure for user data *)

type web_data = {
    p         : Densemat.t array;
    pivot     : Sundials.LintArray.t array;

    ns        : int;
    mxns      : int;

    mp        : int;
    mq        : int;
    mx        : int;
    my        : int;
    ngrp      : int;
    ngx       : int;
    ngy       : int;
    mxmp      : int;

    jgx       : int array;
    jgy       : int array;
    jigx      : int array;
    jigy      : int array;
    jxr       : int array;
    jyr       : int array;

    acoef     : float array array;
    bcoef     : float array;
    diff      : float array;

    cox       : float array;
    coy       : float array;

    dx        : float;
    dy        : float;
    srur      : float;

    fsave     : RealArray.t;

    rewt      : Nvector_serial.t;

    mutable arkode_mem : Nvector_serial.kind Arkode.serial_session option;
  }

(* Private Helper Functions *)

(*
  This routine computes the interaction rates for the species
  c_1, ... ,c_ns (stored in c[0],...,c[ns-1]), at one spatial point 
  and at time t.
*)
let web_rates wdata x y ((c : RealArray.t), c_off)
                        ((rate : RealArray.t), rate_off) =
  let acoef = wdata.acoef
  and bcoef = wdata.bcoef
  in
  for i = rate_off to rate_off + ns - 1 do
    rate.{i} <- zero
  done;
  for j = 0 to ns - 1 do
    let c = c.{c_off + j} in
    for i = 0 to ns - 1 do
      rate.{rate_off + i} <- rate.{rate_off + i} +. c *. acoef.(i).(j)
    done
  done;

  let fac = one +. alph *. x *. y in
  for i = 0 to ns - 1 do
    rate.{rate_off + i} <- c.{c_off + i} *. (bcoef.(i) *. fac
                              +. rate.{rate_off + i})
  done

(*
  This routine computes one block of the interaction terms of the
  system, namely block (jx,jy), for use in preconditioning.
  Here jx and jy count from 0.
*)
let fblock wdata t (cdata : RealArray.t) jx jy (cdotdata : RealArray.t) =
  let iblok = jx + jy * wdata.mx
  and y = float jy *. wdata.dy
  and x = float jx *. wdata.dx
  in
  let ic = wdata.ns * iblok in
  web_rates wdata x y (cdata, ic) (cdotdata, 0)

(* Small Vector Kernels *)

let v_sum_prods ((u : RealArray.t), u_off) p ((q : RealArray.t), q_off) v
                ((w : RealArray.t), w_off) =
  for i = 0 to ns - 1 do
    u.{u_off + i} <- p.(i) *. q.{q_off + i} +. v.(i) *. w.{w_off + i}
  done

(* Functions Called By The Solver *)

(*
 This routine generates the block-diagonal part of the Jacobian
 corresponding to the interaction rates, multiplies by -gamma, adds
 the identity matrix, and calls denseGETRF to do the LU decomposition of
 each diagonal block. The computation of the diagonal blocks uses
 the preset block and grouping information. One block per group is
 computed. The Jacobian elements are generated by difference
 quotients using calls to the routine fblock.

 This routine can be regarded as a prototype for the general case
 of a block-diagonal preconditioner. The blocks are of size mp, and
 there are ngrp=ngx*ngy blocks computed in the block-grouping scheme.
*) 
let precond wdata jacarg jok gamma =
  let { Arkode.jac_t   = t;
        Arkode.jac_y   = (cdata : RealArray.t);
        Arkode.jac_fy  = fc;
        Arkode.jac_tmp = (vtemp1, _, _)
      } = jacarg
  in
  let f1 = vtemp1 in
  let arkode_mem =
    match wdata.arkode_mem with
    | Some c -> c | None -> assert false
  and rewtdata  = Nvector.unwrap wdata.rewt
  in
  Arkode.get_err_weights arkode_mem wdata.rewt;

  let uround = Sundials.unit_roundoff
  and p      = wdata.p
  and pivot  = wdata.pivot
  and jxr    = wdata.jxr
  and jyr    = wdata.jyr
  and mp     = wdata.mp
  and srur   = wdata.srur
  and ngx    = wdata.ngx
  and ngy    = wdata.ngy
  and mxmp   = wdata.mxmp
  and fsave  = wdata.fsave
  in
  (* Make mp calls to fblock to approximate each diagonal block of Jacobian.
     Here, fsave contains the base value of the rate vector and 
     r0 is a minimum increment factor for the difference quotient. *)
  
  let fac = Nvector_serial.DataOps.n_vwrmsnorm fc rewtdata in
  let r0 = 1000.0 *. abs_float gamma *. uround *. float neq *. fac in
  let r0 = if r0 = zero then one else r0 in
  
  for igy = 0 to ngy - 1 do
    let jy = jyr.(igy) in
    let if00 = jy * mxmp in
    for igx = 0 to ngx - 1 do
      let jx  = jxr.(igx) in
      let if0 = if00 + jx * mp in
      let ig  = igx + igy * ngx in
      (* Generate ig-th diagonal block *)
      let pdata = Sundials.RealArray2.unwrap p.(ig) in
      for j = 0 to mp - 1 do
        (* Generate the jth column as a difference quotient *)
        let jj = if0 + j in
        let save = cdata.{jj} in
        let r = max (srur *. abs_float save) (r0 /. rewtdata.{jj}) in
        cdata.{jj} <- cdata.{jj} +. r;
        fblock wdata t cdata jx jy f1;
        let fac = -. gamma /. r in
        for i = 0 to mp - 1 do
          pdata.{j, i} <- (f1.{i} -. fsave.{if0 + i}) *. fac
        done;
        cdata.{jj} <- save
      done
    done
  done;
  
  (* Add identity matrix and do LU decompositions on blocks. *)
  let f ig p_ig =
    Densemat.add_identity p_ig;
    Densemat.getrf p_ig pivot.(ig)
  in
  Array.iteri f p;
  true

let v_inc_by_prod ((u : RealArray.t), u_off) v ((w : RealArray.t), w_off) =
  for i = 0 to ns - 1 do
    u.{u_off + i} <- u.{u_off + i} +. v.(i) *. w.{w_off + i}
  done

let v_prod ((u : RealArray.t), u_off) v ((w : RealArray.t), w_off) =
  for i = 0 to ns - 1 do
    u.{u_off + i} <- v.(i) *. w.{w_off + i}
  done

let v_zero ((u : RealArray.t), u_off) =
  for i = u_off to u_off + ns - 1 do
    u.{i} <- zero
  done

(*
  This routine performs ITMAX=5 Gauss-Seidel iterations to compute an
  approximation to (P-inverse)*z, where P = I - gamma*Jd, and
  Jd represents the diffusion contributions to the Jacobian.
  The answer is stored in z on return, and x is a temporary vector.
  The dimensions below assume a global constant NS >= ns.
  Some inner loops of length ns are implemented with the small
  vector kernels v_sum_prods, v_prod, v_inc_by_prod.
*)
let gs_iter wdata gamma zd xd =
  let ns = wdata.ns
  and mx = wdata.mx
  and my = wdata.my
  and mxns = wdata.mxns
  and cox = wdata.cox
  and coy = wdata.coy
  in

  let beta  = Array.make ns 0.0
  and beta2 = Array.make ns 0.0
  and cof1  = Array.make ns 0.0
  and gam   = Array.make ns 0.0
  and gam2  = Array.make ns 0.0
  in

  (* Write matrix as P = D - L - U.
     Load local arrays beta, beta2, gam, gam2, and cof1. *)
  
  for i = 0 to ns - 1 do
    let temp = one /. (one +. 2.0 *. gamma *. (cox.(i) +. coy.(i))) in
    beta.(i)  <- gamma *. cox.(i) *. temp;
    beta2.(i) <- 2.0 *. beta.(i);
    gam.(i)   <- gamma *. coy.(i) *. temp;
    gam2.(i)  <- 2.0 *. gam.(i);
    cof1.(i)  <- temp
  done;
  
  (* Begin iteration loop.
     Load vector x with (D-inverse)*z for first iteration. *)
  for jy = 0 to my - 1 do
    let iyoff = mxns * jy in
    for jx = 0 to mx - 1 do
      let ic = iyoff + ns*jx in
      v_prod (xd, ic) cof1 (zd, ic) (* x[ic+i] = cof1[i]z[ic+i] *)
    done
  done;
  Array1.fill zd zero;
  
  (* Looping point for iterations. *)
  
  for iter = 1 to itmax do
    
    (* Calculate (D-inverse)*U*x if not the first iteration. *)
    
    if (iter > 1) then
      for jy = 0 to my - 1 do
        let iyoff = mxns * jy in
        for jx = 0 to mx - 1 do (* order of loops matters *)
          let ic = iyoff + ns * jx
          and x_loc = if jx = 0 then 0 else if jx = mx - 1 then 2 else 1
          and y_loc = if jy = 0 then 0 else if jy = my - 1 then 2 else 1
          in

          match (3 * y_loc + x_loc) with
          | 0 ->
            (* jx == 0, jy == 0 *)
            (* x[ic+i] = beta2[i]x[ic+ns+i] + gam2[i]x[ic+mxns+i] *)
            v_sum_prods (xd, ic) beta2 (xd, ic + ns) gam2 (xd, ic + mxns)

          | 1 ->
            (* 1 <= jx <= mx-2, jy == 0 *)
            (* x[ic+i] = beta[i]x[ic+ns+i] + gam2[i]x[ic+mxns+i] *)
            v_sum_prods (xd, ic) beta (xd, ic + ns) gam2 (xd, ic + mxns)

          | 2 ->
            (* jx == mx-1, jy == 0 *)
            (* x[ic+i] = gam2[i]x[ic+mxns+i] *)
            v_prod (xd, ic) gam2 (xd, ic + mxns)

          | 3 ->
            (* jx == 0, 1 <= jy <= my-2 *)
            (* x[ic+i] = beta2[i]x[ic+ns+i] + gam[i]x[ic+mxns+i] *)
            v_sum_prods (xd, ic) beta2 (xd, ic + ns) gam (xd, ic + mxns)

          | 4 ->
            (* 1 <= jx <= mx-2, 1 <= jy <= my-2 *)
            (* x[ic+i] = beta[i]x[ic+ns+i] + gam[i]x[ic+mxns+i] *)
            v_sum_prods (xd, ic) beta (xd, ic + ns) gam (xd, ic + mxns)

          | 5 ->
            (* jx == mx-1, 1 <= jy <= my-2 *)
            (* x[ic+i] = gam[i]x[ic+mxns+i] *)
            v_prod (xd, ic) gam (xd, ic + mxns)

          | 6 ->
            (* jx == 0, jy == my-1 *)
            (* x[ic+i] = beta2[i]x[ic+ns+i] *)
            v_prod (xd, ic) beta2 (xd, ic + ns)

          | 7 ->
            (* 1 <= jx <= mx-2, jy == my-1 *)
            (* x[ic+i] = beta[i]x[ic+ns+i] *)
            v_prod (xd, ic) beta (xd, ic + ns)

          | 8 ->
            (* jx == mx-1, jy == my-1 *)
            (* x[ic+i] = 0.0 *)
            v_zero (xd, ic)

          | _ -> assert false
        done
      done;  (* end if (iter > 1) *)
    
    (* Overwrite x with [(I - (D-inverse)*L)-inverse]*x. *)
    
    for jy = 0 to my - 1 do
      let iyoff = mxns * jy in
      for jx = 0 to mx - 1 do (* order of loops matters *)
        let ic = iyoff + ns * jx
        and x_loc = if jx = 0 then 0 else if jx = mx - 1 then 2 else 1
        and y_loc = if jy = 0 then 0 else if jy = my - 1 then 2 else 1
        in
        match (3 * y_loc + x_loc) with
        | 0 ->
          (* jx == 0, jy == 0 *)
            ()

        | 1 ->
          (* 1 <= jx <= mx-2, jy == 0 *)
          (* x[ic+i] += beta[i]x[ic-ns+i] *)
          v_inc_by_prod (xd, ic) beta (xd, ic - ns)

        | 2 ->
          (* jx == mx-1, jy == 0 *)
          (* x[ic+i] += beta2[i]x[ic-ns+i] *)
          v_inc_by_prod (xd, ic) beta2 (xd, ic - ns)

        | 3 ->
          (* jx == 0, 1 <= jy <= my-2 *)
          (* x[ic+i] += gam[i]x[ic-mxns+i] *)
          v_inc_by_prod (xd, ic) gam (xd, ic - mxns)

        | 4 ->
          (* 1 <= jx <= mx-2, 1 <= jy <= my-2 *)
          (* x[ic+i] += beta[i]x[ic-ns+i] + gam[i]x[ic-mxns+i] *)
          v_inc_by_prod (xd, ic) beta (xd, ic - ns);
          v_inc_by_prod (xd, ic) gam (xd, ic - mxns)

        | 5 ->
          (* jx == mx-1, 1 <= jy <= my-2 *)
          (* x[ic+i] += beta2[i]x[ic-ns+i] + gam[i]x[ic-mxns+i] *)
          v_inc_by_prod (xd, ic) beta2 (xd, ic - ns);
          v_inc_by_prod (xd, ic) gam (xd, ic - mxns)

        | 6 ->
          (* jx == 0, jy == my-1 *)
          (* x[ic+i] += gam2[i]x[ic-mxns+i] *)
          v_inc_by_prod (xd, ic) gam2 (xd, ic - mxns)

        | 7 ->
          (* 1 <= jx <= mx-2, jy == my-1 *)
          (* x[ic+i] += beta[i]x[ic-ns+i] + gam2[i]x[ic-mxns+i] *)
          v_inc_by_prod (xd, ic) beta (xd, ic - ns);
          v_inc_by_prod (xd, ic) gam2 (xd, ic - mxns)

        | 8 ->
          (* jx == mx-1, jy == my-1 *)
          (* x[ic+i] += beta2[i]x[ic-ns+i] + gam2[i]x[ic-mxns+i] *)
          v_inc_by_prod (xd, ic) beta2 (xd, ic - ns);
          v_inc_by_prod (xd, ic) gam2 (xd, ic - mxns)

        | _ -> assert false
      done
    done;
    
    (* Add increment x to z : z <- z+x *)
    Nvector_serial.DataOps.n_vlinearsum one zd one xd zd
  done

(*
  This routine applies two inverse preconditioner matrices
  to the vector r, using the interaction-only block-diagonal Jacobian
  with block-grouping, denoted Jr, and Gauss-Seidel applied to the
  diffusion contribution to the Jacobian, denoted Jd.
  It first calls GSIter for a Gauss-Seidel approximation to
  ((I - gamma*Jd)-inverse)*r, and stores the result in z.
  Then it computes ((I - gamma*Jr)-inverse)*z, using LU factors of the
  blocks in P, and pivot information in pivot, and returns the result in z.
*)
let psolve wdata jac_arg solve_arg z =
  let { Arkode.jac_tmp = vtemp; } = jac_arg
  and { Arkode.Spils.rhs = r;
        Arkode.Spils.gamma = gamma } = solve_arg
  in
  Array1.blit r z;

  (* call GSIter for Gauss-Seidel iterations *)
  gs_iter wdata gamma z vtemp;
  
  (* Do backsolves for inverse of block-diagonal preconditioner factor *)
  let p     = wdata.p
  and pivot = wdata.pivot
  and mx    = wdata.mx
  and my    = wdata.my
  and ngx   = wdata.ngx
  and mp    = wdata.mp
  and jigx  = wdata.jigx
  and jigy  = wdata.jigy
  in
  
  let iv = ref 0 in
  for jy = 0 to my - 1 do
    let igy = jigy.(jy) in
    for jx = 0 to mx - 1 do
      let igx = jigx.(jx) in
      let ig = igx + igy * ngx in
      Densemat.getrs' p.(ig) pivot.(ig) z !iv;
      iv := !iv + mp
    done
  done

(* Private function to check function return values *)

(* Implementation *)

(*
 This routine computes the right-hand side of the ODE system and
 returns it in cdot. The interaction rates are computed by calls to WebRates,
 and these are saved in fsave for use in preconditioning.
*)
let f wdata t cdata (cdotdata : RealArray.t) =
  let ns    = wdata.ns
  and fsave = wdata.fsave
  and cox   = wdata.cox
  and coy   = wdata.coy
  and mxns  = wdata.mxns
  and dx    = wdata.dx
  and dy    = wdata.dy
  in
   
  for jy = 0 to my - 1 do
    let y = float jy *. dy in
    let iyoff = mxns*jy in
    let idyu = if jy = my - 1 then - mxns else mxns in
    let idyl = if jy = 0      then - mxns else mxns in
    for jx = 0 to mx - 1 do
      let x = float jx *. dx in
      let ic = iyoff + ns * jx in
      (* Get interaction rates at one point (x,y). *)
      web_rates wdata x y (cdata, ic) (fsave, ic);
      let idxu = if jx = mx - 1 then -ns else ns in
      let idxl = if jx = 0      then -ns else ns in
      for i = 1 to ns do
        let ici = ic + i - 1 in
        (* Do differencing in y. *)
        let dcyli = cdata.{ici} -. cdata.{ici - idyl} in
        let dcyui = cdata.{ici + idyu} -. cdata.{ici} in
        (* Do differencing in x. *)
        let dcxli = cdata.{ici} -. cdata.{ici - idxl} in
        let dcxui = cdata.{ici + idxu} -. cdata.{ici} in
        (* Collect terms and load cdot elements. *)
        cdotdata.{ici} <- coy.(i - 1) *. (dcyui -. dcyli)
                          +. cox.(i - 1) *. (dcxui -. dcxli)
                          +. fsave.{ici}
      done
    done
  done

(*
 This routine sets arrays jg, jig, and jr describing
 a uniform partition of (0,1,2,...,m-1) into ng groups.
 The arrays set are:
   jg    = length ng+1 array of group boundaries.
           Group ig has indices j = jg[ig],...,jg[ig+1]-1.
   jig   = length m array of group indices vs node index.
           Node index j is in group jig[j].
   jr    = length ng array of indices representing the groups.
           The index for group ig is j = jr[ig].
*)
let set_groups m ng jg jig jr =
  let mper = m / ng in (* does integer division *)

  for ig = 0 to ng - 1 do
    jg.(ig) <- ig * mper
  done;
  jg.(ng) <- m;

  let ngm1 = ng - 1 in
  let len1 = ngm1 * mper in

  for j = 0 to len1 - 1 do
    jig.(j) <- j / mper
  done;

  for j = len1 to m - 1 do
    jig.(j) <- ngm1
  done;

  for ig = 0 to ngm1 - 1 do
    jr.(ig) <- ((2 * ig + 1) * mper - 1) / 2;
  done;
  jr.(ngm1) <- (ngm1 * mper + m - 1) / 2

let alloc_user_data () =
  let r =
    {
      p         = Array.init ngrp (fun _ -> Densemat.create ns ns);
      pivot     = Array.init ngrp (fun _ -> LintArray.create ns);

      ns        = ns;
      mxns      = mxns;

      mp        = mp;
      mq        = mq;
      mx        = mx;
      my        = my;
      ngrp      = ngrp;
      ngx       = ngx;
      ngy       = ngy;
      mxmp      = mxmp;

      jgx       = Array.make (ngx + 1) 0;
      jgy       = Array.make (ngy + 1) 0;
      jigx      = Array.make mx 0;
      jigy      = Array.make my 0;
      jxr       = Array.make ngx 0;
      jyr       = Array.make ngy 0;

      acoef     = Array.make_matrix ns ns 0.0;
      bcoef     = Array.make ns 0.0;
      diff      = Array.make ns 0.0;

      cox       = Array.make ns 0.0;
      coy       = Array.make ns 0.0;

      dx        = dx;
      dy        = dy;
      srur      = sqrt Sundials.unit_roundoff;

      fsave     = RealArray.create neq;

      rewt      = Nvector_serial.wrap (RealArray.create neq);

      arkode_mem = None;
    }
  in
  let acoef = r.acoef
  and bcoef = r.bcoef
  and diff  = r.diff
  and cox   = r.cox
  and coy   = r.coy
  in
  for j = 0 to np - 1 do
    for i = 0 to np - 1 do
      acoef.(np + i).(j) <- ee;
      acoef.(i).(np + j) <- -. gg
    done;
    acoef.(j).(j)           <- -. aa;
    acoef.(np + j).(np + j) <- -. aa;
    bcoef.(j)              <- bb;
    bcoef.(np + j)         <- -. bb;
    diff.(j)               <- dprey;
    diff.(np + j)          <- dpred
  done;

  for i = 0 to ns - 1 do
    cox.(i) <- diff.(i) /. sqr dx;
    coy.(i) <- diff.(i) /. sqr dy
  done;

  r

let init_user_data wdata =
  set_groups mx ngx wdata.jgx wdata.jigx wdata.jxr;
  set_groups my ngy wdata.jgy wdata.jigy wdata.jyr

(* This routine computes and loads the vector of initial values. *)
let cinit wdata (cdata : RealArray.t) =
  let ns   = wdata.ns
  and mxns = wdata.mxns
  and dx   = wdata.dx
  and dy   = wdata.dy
  in
  let x_factor = 4.0 /. sqr ax
  and y_factor = 4.0 /. sqr ay
  in

  for jy = 0 to my - 1 do
    let y     = float jy *. dy in
    let argy  = sqr (y_factor *. y *. (ay -. y)) in
    let iyoff = mxns * jy in
    for jx = 0 to mx - 1 do
      let x = float jx *. dx in
      let argx = sqr (x_factor *. x *. (ax -. x)) in
      let ioff = iyoff + ns * jx in
      for i = 1 to ns do
        let ici = ioff + i - 1 in
        cdata.{ici} <- 10.0 +. float i *. argx *. argy
      done
    done
  done

let print_intro () =
  printf "\n\nDemonstration program for ARKODE - ARKSPGMR linear solver\n\n";
  printf "Food web problem with ns species, ns = %d\n" ns;
  printf "Predator-prey interaction and diffusion on a 2-D square\n\n";

  printf "Matrix parameters: a = %.2g   e = %.2g   g = %.2g\n" aa ee gg;
  printf "b parameter = %.2g\n" bb;
  printf "Diffusion coefficients: Dprey = %.2g   Dpred = %.2g\n" dprey dpred;
  printf "Rate parameter alpha = %.2g\n\n" alph;

  printf "Mesh dimensions (mx,my) are %d, %d.  " mx my;
  printf "Total system size is neq = %d \n\n" neq;

  printf "Tolerances: reltol = %.2g, abstol = %.2g \n\n" rtol atol;

  printf "Preconditioning uses a product of:\n";
  printf "  (1) Gauss-Seidel iterations with ";
  printf "itmax = %d iterations, and\n" itmax;
  printf "  (2) interaction-only block-diagonal matrix ";
  printf "with block-grouping\n";
  printf "  Number of diagonal block groups = ngrp = %d" ngrp;
  printf "  (ngx by ngy, ngx = %d, ngy = %d)\n" ngx ngy;
  printf "\n\n--------------------------------------------------------------";
  printf "--------------\n"

let print_header jpre gstype =
  printf "\n\nPreconditioner type is           jpre = %s\n"
    (if jpre = Spils.PrecLeft then "PREC_LEFT" else "PREC_RIGHT");
  printf"\nGram-Schmidt method type is    gstype = %s\n\n\n"
    (if gstype = Spils.ModifiedGS then "MODIFIED_GS" else "CLASSICAL_GS")

let print_all_species (cdata : RealArray.t) ns mxns t =
  printf "c values at t = %g:\n\n" t;

  for i = 1 to ns do
    printf "Species %d\n" i;
    for jy = my - 1 downto 0 do
      for jx = 0 to mx - 1 do
        printf "%-10.6g" cdata.{(i - 1) + jx * ns + jy * mxns}
      done;
      printf "\n"
    done;
    printf "\n"
  done

let print_output s t =
  let nst     = Arkode.get_num_steps s
  and nfe,nfi = Arkode.get_num_rhs_evals s
  and nni     = Arkode.get_num_nonlin_solv_iters s
  and hu      = Arkode.get_last_step s
  in
  printf "t = %10.2e  nst = %d  nfe = %d  nfi = %d  nni = %d" t nst nfe nfi nni;
  printf "  hu = %11.2e\n\n" hu

let print_final_stats s =
  let open Arkode in
  let lenrw, leniw = get_work_space s
  and nst          = get_num_steps s
  and nfe, nfi     = get_num_rhs_evals s
  and nsetups      = get_num_lin_solv_setups s
  and netf         = get_num_err_test_fails s
  and nni          = get_num_nonlin_solv_iters s
  and ncfn         = get_num_nonlin_solv_conv_fails s
  in
  let lenrwLS, leniwLS = Spils.get_work_space s
  and nli   = Spils.get_num_lin_iters s
  and npe   = Spils.get_num_prec_evals s
  and nps   = Spils.get_num_prec_solves s
  and ncfl  = Spils.get_num_conv_fails s
  and nfeLS = Spils.get_num_rhs_evals s
  in

  printf "\n\n Final statistics for this run:\n\n";
  printf " ARKode real workspace length           = %4d \n" lenrw;
  printf " ARKode integer workspace length        = %4d \n" leniw;
  printf " ARKSPGMR real workspace length         = %4d \n" lenrwLS;
  printf " ARKSPGMR integer workspace length      = %4d \n" leniwLS;
  printf " Number of steps                       = %4d \n" nst;
  printf " Number of f-s (explicit)              = %4d \n" nfe;
  printf " Number of f-s (implicit)              = %4d \n" nfi;
  printf " Number of f-s (SPGMR)                 = %4d \n" nfeLS;
  printf " Number of f-s (TOTAL)                 = %4d \n" (nfe + nfeLS);
  printf " Number of setups                      = %4d \n" nsetups;
  printf " Number of nonlinear iterations        = %4d \n" nni;
  printf " Number of linear iterations           = %4d \n" nli;
  printf " Number of preconditioner evaluations  = %4d \n" npe;
  printf " Number of preconditioner solves       = %4d \n" nps;
  printf " Number of error test failures         = %4d \n" netf;
  printf " Number of nonlinear conv. failures    = %4d \n" ncfn;
  printf " Number of linear convergence failures = %4d \n" ncfl;
  let avdim = if nni > 0 then (float nli /. float nni) else zero in
  printf " Average Krylov subspace dimension     = %.3f \n" avdim;
  printf "\n\n--------------------------------------------------------------";
  printf "--------------\n";
  printf     "--------------------------------------------------------------";
  printf "--------------\n"

let main () =
  let abstol = atol
  and reltol = rtol
  in
  (* Initializations *)
  let c = Nvector_serial.make neq 0.0 in
  let wdata = alloc_user_data () in
  init_user_data wdata;
  cinit wdata (unwrap c);

  (* Call ARKodeInit or ARKodeReInit, then ARKSpgmr to set up problem *)
  let arkode_mem = Arkode.(
    init
      (Implicit
        (f wdata,
         Newton Spils.(spgmr ~maxl:maxl
                             (prec_left ~setup:(precond wdata) (psolve wdata))),
         Nonlinear))
      (SStolerances (reltol, abstol))
      t0
      c
  ) in
  wdata.arkode_mem <- Some arkode_mem;
  Arkode.set_max_num_steps arkode_mem 1000;
  Arkode.set_nonlin_conv_coef arkode_mem 1.0e-3;
  Arkode.Spils.set_gs_type arkode_mem Spils.ModifiedGS;
  Arkode.Spils.set_eps_lin arkode_mem delt;

  let ns   = wdata.ns
  and mxns = wdata.mxns
  in

  (* Print problem description *)
  print_intro ();
  
  let firstrun = ref true in
  let run jpre gstype =
    (* Initialize c and print heading *)
    cinit wdata (unwrap c);
    print_header jpre gstype;

    if !firstrun then
      (* Print initial values *)
      print_all_species (unwrap c) ns mxns t0
    else begin
      Arkode.reinit arkode_mem t0 c;
      Arkode.Spils.set_prec_type arkode_mem jpre;
      Arkode.Spils.set_gs_type arkode_mem gstype
    end;
    
    (* Loop over output points, call ARKode, print sample solution values. *)
    let tout = ref t1 in
    for iout = 1 to nout do
      let (t, _) = Arkode.solve_normal arkode_mem !tout c in
      print_output arkode_mem t;
      if !firstrun && (iout mod 3 = 0)
        then print_all_species (unwrap c) ns mxns t;
      tout := if !tout > 0.9 then !tout +. dtout else !tout *. tout_mult
    done;
    
    (* Print final statistics, and loop for next case *)
    print_final_stats arkode_mem;

    firstrun := false
  in
      
  (* Loop over jpre and gstype (four cases) *)
  let open Spils in
  run PrecLeft  ModifiedGS;
  run PrecLeft  ClassicalGS;
  run PrecRight ModifiedGS;
  run PrecRight ClassicalGS

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
