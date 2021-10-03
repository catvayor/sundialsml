(*--------------------------------------------------------------- {{{
 * Programmer(s): Daniel R. Reynolds @ SMU
 *---------------------------------------------------------------
 * OCaml port: Timothy Bourke, Inria, Jan 2016.
 *---------------------------------------------------------------
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
 * Example problem:
 *
 * The following test simulates a brusselator problem from chemical
 * kinetics.  This is a PDE system with 3 comp1.0nts, Y = [u,v,w],
 * satisfying the equations,
 *    u_t = du*u_xx + a - (w+1)*u + v*u^2
 *    v_t = dv*v_xx + w*u - v*u^2
 *    w_t = dw*w_xx + (b-w)/ep - w*u
 * for t in [0, 80], x in [0, 1], with initial conditions
 *    u(0,x) =  a  + 0.1*sin(pi*x)
 *    v(0,x) = b/a + 0.1*sin(pi*x)
 *    w(0,x) =  b  + 0.1*sin(pi*x),
 * and with stationary boundary conditions, i.e.
 *    u_t(t,0) = u_t(t,1) = 0
 *    v_t(t,0) = v_t(t,1) = 0
 *    w_t(t,0) = w_t(t,1) = 0.
 *
 * Here, we use a piecewise linear Galerkin finite element
 * discretization in space, where all element-wise integrals are
 * computed using 3-node Gaussian quadrature (since we will have
 * quartic polynomials in the reaction terms for the u_t and v_t
 * equations, including the test function).  The time derivative
 * terms for this system will include a mass matrix, giving rise
 * to an ODE system of the form
 *      M y_t = L y + R(y),
 * where M is the block mass matrix for each comp1.0nt, L is
 * the block Laplace operator for each comp1.0nt, and R(y) is
 * a 3x3 block comprised of the nonlinear reaction terms for
 * each comp1.0nt.  Since it it highly inefficient to rewrite
 * this system as
 *      y_t = M^{-1}(L y + R(y)),
 * we solve this system using ARKode, with a user-supplied mass
 * matrix.  We therefore provide functions to evaluate the ODE RHS
 *    f(t,y) = L y + R(y),
 * its Jacobian
 *    J(t,y) = L + dR/dy,
 * and the mass matrix, M.
 *
 * This program solves the problem with the DIRK method, using a
 * Newton iteration with the ARKSUPERLUMT sparse linear solver.
 *
 * 100 outputs are printed at equal time intervals, and run
 * statistics are printed at the end.
 *--------------------------------------------------------------- }}} *)

open Sundials
module ARKStep = Arkode.ARKStep

let sungte500 =
  let n, _, _ = Sundials.Config.sundials_version in
  n >= 5

let printf = Printf.printf
let fprintf = Printf.fprintf
let unwrap = Nvector_serial.unwrap
let wl2norm = Nvector_serial.Ops.wl2norm

(* accessor macros between (x,v) location and 1D NVector array *)
(* [variables are grouped according to spatial location] *)
let idx x v = 3*x+v

(* Gaussian quadrature nodes, weights and formula
        (3 node, 7th-order accurate) *)
let x1(xl,xr) = 0.5*.(xl+.xr) -. 0.5*.(xr-.xl)*.0.774596669241483377035853079956
let x2(xl,xr) = 0.5*.(xl+.xr)
let x3(xl,xr) = 0.5*.(xl+.xr) +. 0.5*.(xr-.xl)*.0.774596669241483377035853079956
let w1        = 0.55555555555555555555555555555556
let w2        = 0.88888888888888888888888888888889
let w3        = 0.55555555555555555555555555555556
let quad(f1,f2,f3,xl,xr) = 0.5*.(xr-.xl)*.(w1*.f1 +. w2*.f2 +. w3*.f3)

(* evaluation macros for variables, basis functions and basis derivatives *)
let chiL(xl,xr,x) = (xr-.x)/.(xr-.xl)
let chiR(xl,xr,x) = (x-.xl)/.(xr-.xl)
let chiL_x(xl,xr) = 1.0/.(xl-.xr)
let chiR_x(xl,xr) = 1.0/.(xr-.xl)
let eval(ul,ur,xl,xr,x) = ul*.chiL(xl,xr,x) +. ur*.chiR(xl,xr,x)
let eval_x(ul,ur,xl,xr) = ul*.chiL_x(xl,xr) +. ur*.chiR_x(xl,xr)

(* user data structure *)
type user_data = {
  n   : int;                            (* number of intervals     *)
  x   : RealArray.t;                    (* mesh node locations     *)
  a   : float;                          (* constant forcing on u   *)
  b   : float;                          (* steady-state value of w *)
  du  : float;                          (* diffusion coeff for u   *)
  dv  : float;                          (* diffusion coeff for v   *)
  dw  : float;                          (* diffusion coeff for w   *)
  ep  : float;                          (* stiffness parameter     *)
}

module Csc = struct (* {{{ *)

  type smat = Matrix.Sparse.csc

  let newmat ?nnz neq = Matrix.sparse_csc ?nnz neq
  let makemat = Matrix.Sparse.(make CSC)

  (* Routine to compute the Laplace matrix *)
  let laplace_matrix { n; du; dv; dw; x } l =
    let nz = ref 0 in
    let set_col j = Matrix.Sparse.set_col l j !nz in
    let set j v = (Matrix.Sparse.set l !nz j v; incr nz) in

    (* iterate over columns, filling in Laplace matrix entries *)
    for i=0 to n-1 do
      (* dependence on u at this node *)
      set_col (idx i 0);

      if i>1 then begin
        let xl = x.{i-1} in
        let xr = x.{i} in
        set (idx (i-1) 0) ((-.du) *. quad(1.0,1.0,1.0,xl,xr)
                                  *. chiL_x(xl,xr) *. chiR_x(xl,xr))
      end;
      if i<n-1 && i>0 then begin
        let xl = x.{i-1} in
        let xr = x.{i} in
        let d = (-.du) *. quad(1.0,1.0,1.0,xl,xr)
                       *. chiR_x(xl,xr) *. chiR_x(xl,xr) in
        let xl = x.{i} in
        let xr = x.{i+1} in
        set (idx i 0) (d +. (-.du) *. quad(1.0,1.0,1.0,xl,xr)
                                   *. chiL_x(xl,xr) *. chiL_x(xl,xr))
      end;

      if i<n-2 then begin
        let xl = x.{i} in
        let xr = x.{i+1} in
        set (idx (i+1) 0) ((-.du) *. quad(1.0,1.0,1.0,xl,xr)
                                  *. chiL_x(xl,xr) *. chiR_x(xl,xr))
      end;

      (* dependence on v at this node *)
      set_col (idx i 1);

      if i>1 then begin
        let xl = x.{i-1} in
        let xr = x.{i} in
        set (idx (i-1) 1) ((-.dv) *. quad(1.0,1.0,1.0,xl,xr)
                                  *. chiL_x(xl,xr) *. chiR_x(xl,xr))
      end;
      if i>0 && i<n-1 then begin
        let xl = x.{i} in
        let xr = x.{i+1} in
        let d = (-.dv) *. quad(1.0,1.0,1.0,xl,xr)
                       *. chiL_x(xl,xr) *. chiL_x(xl,xr) in
        let xl = x.{i-1} in
        let xr = x.{i} in
        set (idx i 1) (d +. (-.dv) *. quad(1.0,1.0,1.0,xl,xr)
                                   *. chiR_x(xl,xr) *. chiR_x(xl,xr))
      end;
      if i<n-2 then begin
        let xl = x.{i} in
        let xr = x.{i+1} in
        set (idx (i+1) 1) ((-.dv) *. quad(1.0,1.0,1.0,xl,xr)
                                  *. chiL_x(xl,xr) *. chiR_x(xl,xr))
      end;

      (* dependence on w at this node *)
      set_col (idx i 2);

      if i>1 then begin
        let xl = x.{i-1} in
        let xr = x.{i} in
        set (idx (i-1) 2) ((-.dw) *. quad(1.0,1.0,1.0,xl,xr)
                                  *. chiL_x(xl,xr) *. chiR_x(xl,xr))
      end;
      if i>0 && i<n-1 then begin
        let xl = x.{i} in
        let xr = x.{i+1} in
        let d = (-.dw) *. quad(1.0,1.0,1.0,xl,xr)
                       *. chiL_x(xl,xr) *. chiL_x(xl,xr) in
        let xl = x.{i-1} in
        let xr = x.{i} in
        set (idx i 2) (d +. (-.dw) *. quad(1.0,1.0,1.0,xl,xr)
                                   *. chiR_x(xl,xr) *. chiR_x(xl,xr))
      end;
      if i<n-2 then begin
        let xl = x.{i} in
        let xr = x.{i+1} in
        set (idx (i+1) 2) ((-.dw) *. quad(1.0,1.0,1.0,xl,xr)
                                  *. chiL_x(xl,xr) *. chiR_x(xl,xr))
      end
    done;

    (* signal end of data *)
    set_col ((idx (n-1) 2)+1)

  (* Routine to compute the Jacobian matrix from R(y) *)
  let reaction_jac { n; ep; x } (y : RealArray.t) jac =
    let nz = ref 0 in
    let set_col j = Matrix.Sparse.set_col jac j !nz in
    let set j v = (Matrix.Sparse.set jac !nz j v; incr nz) in

    (* iterate over columns, filling in reaction Jacobian *)
    for i=0 to n-1 do
      (* set mesh shortcuts *)
      let xl = if i>0   then x.{i-1} else 0.0 in
      let xc = x.{i} in
      let xr = if i<n-1 then x.{i+1} else 0.0 in

      (* set nodal value shortcuts *)
      let ul, vl, wl =
        if i > 0 then y.{idx (i-1) 0}, y.{idx (i-1) 1}, y.{idx (i-1) 2}
        else 0.0, 0.0, 0.0 in

      let uc = y.{idx i 0} in
      let vc = y.{idx i 1} in
      let wc = y.{idx i 2} in

      let ur, vr, wr =
        if i<n-1 then y.{idx (i+1) 0}, y.{idx (i+1) 1}, y.{idx (i+1) 2}
        else 0.0, 0.0, 0.0 in

      let u1l, v1l, w1l, u2l, v2l, w2l, u3l, v3l, w3l =
        if i > 0 then
          eval(ul,uc,xl,xc,x1(xl,xc)),
          eval(vl,vc,xl,xc,x1(xl,xc)),
          eval(wl,wc,xl,xc,x1(xl,xc)),
          eval(ul,uc,xl,xc,x2(xl,xc)),
          eval(vl,vc,xl,xc,x2(xl,xc)),
          eval(wl,wc,xl,xc,x2(xl,xc)),
          eval(ul,uc,xl,xc,x3(xl,xc)),
          eval(vl,vc,xl,xc,x3(xl,xc)),
          eval(wl,wc,xl,xc,x3(xl,xc))
        else 0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0
      in

      let u1r, v1r, w1r, u2r, v2r, w2r, u3r, v3r, w3r =
        if i<n-1 then
          eval(uc,ur,xc,xr,x1(xc,xr)),
          eval(vc,vr,xc,xr,x1(xc,xr)),
          eval(wc,wr,xc,xr,x1(xc,xr)),
          eval(uc,ur,xc,xr,x2(xc,xr)),
          eval(vc,vr,xc,xr,x2(xc,xr)),
          eval(wc,wr,xc,xr,x2(xc,xr)),
          eval(uc,ur,xc,xr,x3(xc,xr)),
          eval(vc,vr,xc,xr,x3(xc,xr)),
          eval(wc,wr,xc,xr,x3(xc,xr))
        else 0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0
      in

      (* set partial derivative shortcuts *)
      let dQdf1l, dQdf2l, dQdf3l, chiL1l, chiL2l, chiL3l, chiR1l, chiR2l, chiR3l =
        if i>0 then
          quad(1.0, 0.0, 0.0, xl, xc),
          quad(0.0, 1.0, 0.0, xl, xc),
          quad(0.0, 0.0, 1.0, xl, xc),
          chiL(xl,xc,x1(xl,xc)),
          chiL(xl,xc,x2(xl,xc)),
          chiL(xl,xc,x3(xl,xc)),
          chiR(xl,xc,x1(xl,xc)),
          chiR(xl,xc,x2(xl,xc)),
          chiR(xl,xc,x3(xl,xc))
        else 0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0
      in

      let dQdf1r, dQdf2r, dQdf3r, chiL1r, chiL2r, chiL3r, chiR1r, chiR2r, chiR3r =
        if i<n-1 then
          quad(1.0, 0.0, 0.0, xc, xr),
          quad(0.0, 1.0, 0.0, xc, xr),
          quad(0.0, 0.0, 1.0, xc, xr),
          chiL(xc,xr,x1(xc,xr)),
          chiL(xc,xr,x2(xc,xr)),
          chiL(xc,xr,x3(xc,xr)),
          chiR(xc,xr,x1(xc,xr)),
          chiR(xc,xr,x2(xc,xr)),
          chiR(xc,xr,x3(xc,xr))
        else 0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0
      in

      (*** evaluate dR/dy at this node ***)

      (* dependence on u at this node *)
      set_col (idx i 0);

      if i>1 then begin
        (*  dR_ul/duc *)
        let df1 = (-.(w1l+.1.0) +. 2.0*.v1l*.u1l) *. chiL1l *. chiR1l in
        let df2 = (-.(w2l+.1.0) +. 2.0*.v2l*.u2l) *. chiL2l *. chiR2l in
        let df3 = (-.(w3l+.1.0) +. 2.0*.v3l*.u3l) *. chiL3l *. chiR3l in
        set (idx (i-1) 0) (dQdf1l*.df1 +. dQdf2l*.df2 +. dQdf3l*.df3);

        (*  dR_vl/duc *)
        let df1 = (w1l -. 2.0*.v1l*.u1l) *. chiL1l *. chiR1l in
        let df2 = (w2l -. 2.0*.v2l*.u2l) *. chiL2l *. chiR2l in
        let df3 = (w3l -. 2.0*.v3l*.u3l) *. chiL3l *. chiR3l in
        set (idx (i-1) 1) (dQdf1l*.df1 +. dQdf2l*.df2 +. dQdf3l*.df3);

        (*  dR_wl/duc *)
        let df1 = (-.w1l) *. chiL1l *. chiR1l in
        let df2 = (-.w2l) *. chiL2l *. chiR2l in
        let df3 = (-.w3l) *. chiL3l *. chiR3l in
        set (idx (i-1) 2) (dQdf1l*.df1 +. dQdf2l*.df2 +. dQdf3l*.df3)
      end;
      if i>0 && i<n-1 then begin
        (*  dR_uc/duc *)
        let df1 = (-.(w1r+.1.0) +. 2.0*.v1r*.u1r) *. chiL1r *. chiL1r in
        let df2 = (-.(w2r+.1.0) +. 2.0*.v2r*.u2r) *. chiL2r *. chiL2r in
        let df3 = (-.(w3r+.1.0) +. 2.0*.v3r*.u3r) *. chiL3r *. chiL3r in
        let d = dQdf1r*.df1 +. dQdf2r*.df2 +. dQdf3r*.df3 in

        let df1 = (-.(w1l+.1.0) +. 2.0*.v1l*.u1l) *. chiR1l *. chiR1l in
        let df2 = (-.(w2l+.1.0) +. 2.0*.v2l*.u2l) *. chiR2l *. chiR2l in
        let df3 = (-.(w3l+.1.0) +. 2.0*.v3l*.u3l) *. chiR3l *. chiR3l in
        set (idx i 0) (d +. dQdf1l*.df1 +. dQdf2l*.df2 +. dQdf3l*.df3);

        (*  dR_vc/duc *)
        let df1 = (w1l -. 2.0*.v1l*.u1l) *. chiR1l *. chiR1l in
        let df2 = (w2l -. 2.0*.v2l*.u2l) *. chiR2l *. chiR2l in
        let df3 = (w3l -. 2.0*.v3l*.u3l) *. chiR3l *. chiR3l in
        let d = dQdf1l*.df1 +. dQdf2l*.df2 +. dQdf3l*.df3 in

        let df1 = (w1r -. 2.0*.v1r*.u1r) *. chiL1r *. chiL1r in
        let df2 = (w2r -. 2.0*.v2r*.u2r) *. chiL2r *. chiL2r in
        let df3 = (w3r -. 2.0*.v3r*.u3r) *. chiL3r *. chiL3r in
        set (idx i 1) (d +. dQdf1r*.df1 +. dQdf2r*.df2 +. dQdf3r*.df3);

        (*  dR_wc/duc *)
        let df1 = (-.w1r) *. chiL1r *. chiL1r in
        let df2 = (-.w2r) *. chiL2r *. chiL2r in
        let df3 = (-.w3r) *. chiL3r *. chiL3r in
        let d = dQdf1r*.df1 +. dQdf2r*.df2 +. dQdf3r*.df3 in

        let df1 = (-.w1l) *. chiR1l *. chiR1l in
        let df2 = (-.w2l) *. chiR2l *. chiR2l in
        let df3 = (-.w3l) *. chiR3l *. chiR3l in
        set (idx i 2) (d +. dQdf1l*.df1 +. dQdf2l*.df2 +. dQdf3l*.df3)
      end;
      if i<n-2 then begin
        (*  dR_ur/duc *)
        let df1 = (-.(w1r+.1.0) +. 2.0*.v1r*.u1r) *. chiL1r *. chiR1r in
        let df2 = (-.(w2r+.1.0) +. 2.0*.v2r*.u2r) *. chiL2r *. chiR2r in
        let df3 = (-.(w3r+.1.0) +. 2.0*.v3r*.u3r) *. chiL3r *. chiR3r in
        set (idx (i+1) 0) (dQdf1r*.df1 +. dQdf2r*.df2 +. dQdf3r*.df3);

        (*  dR_vr/duc *)
        let df1 = (w1r -. 2.0*.v1r*.u1r) *. chiL1r *. chiR1r in
        let df2 = (w2r -. 2.0*.v2r*.u2r) *. chiL2r *. chiR2r in
        let df3 = (w3r -. 2.0*.v3r*.u3r) *. chiL3r *. chiR3r in
        set (idx (i+1) 1) (dQdf1r*.df1 +. dQdf2r*.df2 +. dQdf3r*.df3);

        (*  dR_wr/duc *)
        let df1 = (-.w1r) *. chiL1r *. chiR1r in
        let df2 = (-.w2r) *. chiL2r *. chiR2r in
        let df3 = (-.w3r) *. chiL3r *. chiR3r in
        set (idx (i+1) 2) (dQdf1r*.df1 +. dQdf2r*.df2 +. dQdf3r*.df3)
      end;

      (* dependence on v at this node *)
      set_col (idx i 1);

      if i>1 then begin
        (*  dR_ul/dvc *)
        let df1 = (u1l*.u1l) *. chiL1l *. chiR1l in
        let df2 = (u2l*.u2l) *. chiL2l *. chiR2l in
        let df3 = (u3l*.u3l) *. chiL3l *. chiR3l in
        set (idx (i-1) 0) (dQdf1l*.df1 +. dQdf2l*.df2 +. dQdf3l*.df3);

        (*  dR_vl/dvc *)
        let df1 = (-.u1l*.u1l) *. chiL1l *. chiR1l in
        let df2 = (-.u2l*.u2l) *. chiL2l *. chiR2l in
        let df3 = (-.u3l*.u3l) *. chiL3l *. chiR3l in
        set (idx (i-1) 1) (dQdf1l*.df1 +. dQdf2l*.df2 +. dQdf3l*.df3)
      end;
      if i>0 && i<n-1 then begin
        (*  dR_uc/dvc *)
        let df1 = (u1l*.u1l) *. chiR1l *. chiR1l in
        let df2 = (u2l*.u2l) *. chiR2l *. chiR2l in
        let df3 = (u3l*.u3l) *. chiR3l *. chiR3l in
        let d = dQdf1l*.df1 +. dQdf2l*.df2 +. dQdf3l*.df3 in

        let df1 = (u1r*.u1r) *. chiL1r *. chiL1r in
        let df2 = (u2r*.u2r) *. chiL2r *. chiL2r in
        let df3 = (u3r*.u3r) *. chiL3r *. chiL3r in
        set (idx i 0) (d +. dQdf1r*.df1 +. dQdf2r*.df2 +. dQdf3r*.df3);

        (*  dR_vc/dvc *)
        let df1 = (-.u1l*.u1l) *. chiR1l *. chiR1l in
        let df2 = (-.u2l*.u2l) *. chiR2l *. chiR2l in
        let df3 = (-.u3l*.u3l) *. chiR3l *. chiR3l in
        let d = dQdf1l*.df1 +. dQdf2l*.df2 +. dQdf3l*.df3 in

        let df1 = (-.u1r*.u1r) *. chiL1r *. chiL1r in
        let df2 = (-.u2r*.u2r) *. chiL2r *. chiL2r in
        let df3 = (-.u3r*.u3r) *. chiL3r *. chiL3r in
        set (idx i 1) (d +. dQdf1r*.df1 +. dQdf2r*.df2 +. dQdf3r*.df3)
      end;
      if i<n-2 then begin
        (*  dR_ur/dvc *)
        let df1 = (u1r*.u1r) *. chiL1r *. chiR1r in
        let df2 = (u2r*.u2r) *. chiL2r *. chiR2r in
        let df3 = (u3r*.u3r) *. chiL3r *. chiR3r in
        set (idx (i+1) 0) (dQdf1r*.df1 +. dQdf2r*.df2 +. dQdf3r*.df3);

        (*  dR_vr/dvc *)
        let df1 = (-.u1r*.u1r) *. chiL1r *. chiR1r in
        let df2 = (-.u2r*.u2r) *. chiL2r *. chiR2r in
        let df3 = (-.u3r*.u3r) *. chiL3r *. chiR3r in
        set (idx (i+1) 1) (dQdf1r*.df1 +. dQdf2r*.df2 +. dQdf3r*.df3)
      end;

      (* dependence on w at this node *)
      set_col (idx i 2);

      if i>1 then begin
        (*  dR_ul/dwc *)
        let df1 = (-.u1l) *. chiL1l *. chiR1l in
        let df2 = (-.u2l) *. chiL2l *. chiR2l in
        let df3 = (-.u3l) *. chiL3l *. chiR3l in
        set (idx (i-1) 0) (dQdf1l*.df1 +. dQdf2l*.df2 +. dQdf3l*.df3);

        (*  dR_vl/dwc *)
        let df1 = (u1l) *. chiL1l *. chiR1l in
        let df2 = (u2l) *. chiL2l *. chiR2l in
        let df3 = (u3l) *. chiL3l *. chiR3l in
        set (idx (i-1) 1) (dQdf1l*.df1 +. dQdf2l*.df2 +. dQdf3l*.df3);

        (*  dR_wl/dwc *)
        let df1 = (-.1.0/.ep -. u1l) *. chiL1l *. chiR1l in
        let df2 = (-.1.0/.ep -. u2l) *. chiL2l *. chiR2l in
        let df3 = (-.1.0/.ep -. u3l) *. chiL3l *. chiR3l in
        set (idx (i-1) 2) (dQdf1l*.df1 +. dQdf2l*.df2 +. dQdf3l*.df3)
      end;
      if i>0 && i<n-1 then begin
        (*  dR_uc/dwc *)
        let df1 = (-.u1l) *. chiR1l *. chiR1l in
        let df2 = (-.u2l) *. chiR2l *. chiR2l in
        let df3 = (-.u3l) *. chiR3l *. chiR3l in
        let d = dQdf1l*.df1 +. dQdf2l*.df2 +. dQdf3l*.df3 in

        let df1 = (-.u1r) *. chiL1r *. chiL1r in
        let df2 = (-.u2r) *. chiL2r *. chiL2r in
        let df3 = (-.u3r) *. chiL3r *. chiL3r in
        set (idx i 0) (d +. dQdf1r*.df1 +. dQdf2r*.df2 +. dQdf3r*.df3);

        (*  dR_vc/dwc *)
        let df1 = (u1l) *. chiR1l *. chiR1l in
        let df2 = (u2l) *. chiR2l *. chiR2l in
        let df3 = (u3l) *. chiR3l *. chiR3l in
        let d = dQdf1l*.df1 +. dQdf2l*.df2 +. dQdf3l*.df3 in

        let df1 = (u1r) *. chiL1r *. chiL1r in
        let df2 = (u2r) *. chiL2r *. chiL2r in
        let df3 = (u3r) *. chiL3r *. chiL3r in
        set (idx i 1) (d +. dQdf1r*.df1 +. dQdf2r*.df2 +. dQdf3r*.df3);

        (*  dR_wc/dwc *)
        let df1 = (-.1.0/.ep -. u1l) *. chiR1l *. chiR1l in
        let df2 = (-.1.0/.ep -. u2l) *. chiR2l *. chiR2l in
        let df3 = (-.1.0/.ep -. u3l) *. chiR3l *. chiR3l in
        let d = dQdf1l*.df1 +. dQdf2l*.df2 +. dQdf3l*.df3 in

        let df1 = (-.1.0/.ep -. u1r) *. chiL1r *. chiL1r in
        let df2 = (-.1.0/.ep -. u2r) *. chiL2r *. chiL2r in
        let df3 = (-.1.0/.ep -. u3r) *. chiL3r *. chiL3r in
        set (idx i 2) (d +. dQdf1r*.df1 +. dQdf2r*.df2 +. dQdf3r*.df3)
      end;
      if i<n-2 then begin
        (*  dR_ur/dwc *)
        let df1 = (-.u1r) *. chiL1r *. chiR1r in
        let df2 = (-.u2r) *. chiL2r *. chiR2r in
        let df3 = (-.u3r) *. chiL3r *. chiR3r in
        set (idx (i+1) 0) (dQdf1r*.df1 +. dQdf2r*.df2 +. dQdf3r*.df3);

        (*  dR_vr/dwc *)
        let df1 = (u1r) *. chiL1r *. chiR1r in
        let df2 = (u2r) *. chiL2r *. chiR2r in
        let df3 = (u3r) *. chiL3r *. chiR3r in
        set (idx (i+1) 1) (dQdf1r*.df1 +. dQdf2r*.df2 +. dQdf3r*.df3);

        (*  dR_wr/dwc *)
        let df1 = (-.1.0/.ep -. u1r) *. chiL1r *. chiR1r in
        let df2 = (-.1.0/.ep -. u2r) *. chiL2r *. chiR2r in
        let df3 = (-.1.0/.ep -. u3r) *. chiL3r *. chiR3r in
        set (idx (i+1) 2) (dQdf1r*.df1 +. dQdf2r*.df2 +. dQdf3r*.df3);
      end
    done;

    (* signal end of data *)
    set_col ((idx (n-1) 2)+1)

  (* Routine to compute the mass matrix multiplying y_t. *)
  let mass_matrix { n; x } _ _ m =
    let nz = ref 0 in
    let set_col j = Matrix.Sparse.set_col m j !nz in
    let set j v = (Matrix.Sparse.set m !nz j v; incr nz) in

    (* iterate over columns, filling in matrix entries *)
    for i=0 to n-1 do
      (* dependence on u at this node *)
      set_col (idx i 0);

      (*    left u trial function *)
      if i>0 then begin
        let xl = x.{i-1} in
        let xr = x.{i} in
        let f1 = chiL(xl,xr,x1(xl,xr)) *. chiR(xl,xr,x1(xl,xr)) in
        let f2 = chiL(xl,xr,x2(xl,xr)) *. chiR(xl,xr,x2(xl,xr)) in
        let f3 = chiL(xl,xr,x3(xl,xr)) *. chiR(xl,xr,x3(xl,xr)) in
        set (idx (i-1) 0) (quad(f1,f2,f3,xl,xr))
      end;
      (*    this u trial function *)
      let dtmp = ref 0.0 in
      if i<n-1 then begin
        let xl = x.{i} in
        let xr = x.{i+1} in
        let f1 = chiL(xl,xr,x1(xl,xr)) *. chiL(xl,xr,x1(xl,xr)) in
        let f2 = chiL(xl,xr,x2(xl,xr)) *. chiL(xl,xr,x2(xl,xr)) in
        let f3 = chiL(xl,xr,x3(xl,xr)) *. chiL(xl,xr,x3(xl,xr)) in
        dtmp := !dtmp +. quad(f1,f2,f3,xl,xr)
      end;
      if i>0 then begin
        let xl = x.{i-1} in
        let xr = x.{i} in
        let f1 = chiR(xl,xr,x1(xl,xr)) *. chiR(xl,xr,x1(xl,xr)) in
        let f2 = chiR(xl,xr,x2(xl,xr)) *. chiR(xl,xr,x2(xl,xr)) in
        let f3 = chiR(xl,xr,x3(xl,xr)) *. chiR(xl,xr,x3(xl,xr)) in
        dtmp := !dtmp +. quad(f1,f2,f3,xl,xr)
      end;
      set (idx i 0) !dtmp;
      (*    right u trial function *)
      if i<n-1 then begin
        let xl = x.{i} in
        let xr = x.{i+1} in
        let f1 = chiL(xl,xr,x1(xl,xr)) *. chiR(xl,xr,x1(xl,xr)) in
        let f2 = chiL(xl,xr,x2(xl,xr)) *. chiR(xl,xr,x2(xl,xr)) in
        let f3 = chiL(xl,xr,x3(xl,xr)) *. chiR(xl,xr,x3(xl,xr)) in
        set (idx (i+1) 0) (quad(f1,f2,f3,xl,xr));
      end;

      (* dependence on v at this node *)
      set_col (idx i 1);

      (*    left v trial function *)
      if i>0 then begin
        let xl = x.{i-1} in
        let xr = x.{i} in
        let f1 = chiL(xl,xr,x1(xl,xr)) *. chiR(xl,xr,x1(xl,xr)) in
        let f2 = chiL(xl,xr,x2(xl,xr)) *. chiR(xl,xr,x2(xl,xr)) in
        let f3 = chiL(xl,xr,x3(xl,xr)) *. chiR(xl,xr,x3(xl,xr)) in
        set (idx (i-1) 1) (quad(f1,f2,f3,xl,xr))
      end;
      (*    this v trial function *)
      let dtmp = ref 0.0 in
      if i<n-1 then begin
        let xl = x.{i} in
        let xr = x.{i+1} in
        let f1 = chiL(xl,xr,x1(xl,xr)) *. chiL(xl,xr,x1(xl,xr)) in
        let f2 = chiL(xl,xr,x2(xl,xr)) *. chiL(xl,xr,x2(xl,xr)) in
        let f3 = chiL(xl,xr,x3(xl,xr)) *. chiL(xl,xr,x3(xl,xr)) in
        dtmp := !dtmp +. quad(f1,f2,f3,xl,xr)
      end;
      if i>0 then begin
        let xl = x.{i-1} in
        let xr = x.{i} in
        let f1 = chiR(xl,xr,x1(xl,xr)) *. chiR(xl,xr,x1(xl,xr)) in
        let f2 = chiR(xl,xr,x2(xl,xr)) *. chiR(xl,xr,x2(xl,xr)) in
        let f3 = chiR(xl,xr,x3(xl,xr)) *. chiR(xl,xr,x3(xl,xr)) in
        dtmp := !dtmp +. quad(f1,f2,f3,xl,xr)
      end;
      set (idx i 1) !dtmp;
      (*    right v trial function *)
      if i<n-1 then begin
        let xl = x.{i} in
        let xr = x.{i+1} in
        let f1 = chiL(xl,xr,x1(xl,xr)) *. chiR(xl,xr,x1(xl,xr)) in
        let f2 = chiL(xl,xr,x2(xl,xr)) *. chiR(xl,xr,x2(xl,xr)) in
        let f3 = chiL(xl,xr,x3(xl,xr)) *. chiR(xl,xr,x3(xl,xr)) in
        set (idx (i+1) 1) (quad(f1,f2,f3,xl,xr))
      end;

      (* dependence on w at this node *)
      set_col (idx i 2);

      (*    left w trial function *)
      if i>0 then begin
        let xl = x.{i-1} in
        let xr = x.{i} in
        let f1 = chiL(xl,xr,x1(xl,xr)) *. chiR(xl,xr,x1(xl,xr)) in
        let f2 = chiL(xl,xr,x2(xl,xr)) *. chiR(xl,xr,x2(xl,xr)) in
        let f3 = chiL(xl,xr,x3(xl,xr)) *. chiR(xl,xr,x3(xl,xr)) in
        set (idx (i-1) 2) (quad(f1,f2,f3,xl,xr))
      end;
      (*    this w trial function *)
      let dtmp = ref 0.0 in
      if i<n-1 then begin
        let xl = x.{i} in
        let xr = x.{i+1} in
        let f1 = chiL(xl,xr,x1(xl,xr)) *. chiL(xl,xr,x1(xl,xr)) in
        let f2 = chiL(xl,xr,x2(xl,xr)) *. chiL(xl,xr,x2(xl,xr)) in
        let f3 = chiL(xl,xr,x3(xl,xr)) *. chiL(xl,xr,x3(xl,xr)) in
        dtmp := !dtmp +. quad(f1,f2,f3,xl,xr)
      end;
      if i>0 then begin
        let xl = x.{i-1} in
        let xr = x.{i} in
        let f1 = chiR(xl,xr,x1(xl,xr)) *. chiR(xl,xr,x1(xl,xr)) in
        let f2 = chiR(xl,xr,x2(xl,xr)) *. chiR(xl,xr,x2(xl,xr)) in
        let f3 = chiR(xl,xr,x3(xl,xr)) *. chiR(xl,xr,x3(xl,xr)) in
        dtmp := !dtmp +. quad(f1,f2,f3,xl,xr)
      end;
      set (idx i 2) !dtmp;
      (*    right w trial function *)
      if i<n-1 then begin
        let xl = x.{i} in
        let xr = x.{i+1} in
        let f1 = chiL(xl,xr,x1(xl,xr)) *. chiR(xl,xr,x1(xl,xr)) in
        let f2 = chiL(xl,xr,x2(xl,xr)) *. chiR(xl,xr,x2(xl,xr)) in
        let f3 = chiL(xl,xr,x3(xl,xr)) *. chiR(xl,xr,x3(xl,xr)) in
        set (idx (i+1) 2) (quad(f1,f2,f3,xl,xr))
      end
    done;

    (* signal end of data *)
    set_col ((idx (n-1) 2)+1)

end (* }}} *)

module Csr = struct (* {{{ *)

  type smat = Matrix.Sparse.csr

  let newmat ?nnz neq = Matrix.sparse_csr ?nnz neq
  let makemat = Matrix.Sparse.(make CSR)

  (* Routine to compute the Laplace matrix *)
  let laplace_matrix { n; du; dv; dw; x } l = (* {{{ *)
    let iidx x v = Index.of_int (idx x v) in
    let nz = ref 0 in

    let lu = RealArray.make 9 0.0 in
    let lv = RealArray.make 9 0.0 in
    let lw = RealArray.make 9 0.0 in

    (* clear out matrix *)
    Matrix.Sparse.set_to_zero l;
    let colinds, rowptrs, ldata = Matrix.Sparse.unwrap l in

    (* Dirichlet boundary at left *)
    rowptrs.{idx 0 0} <- Index.of_int !nz;
    rowptrs.{idx 0 1} <- Index.of_int !nz;
    rowptrs.{idx 0 2} <- Index.of_int !nz;

    (* iterate over columns, filling in Laplace matrix *)
    for i = 1 to n-2 do
      (* set nodal value shortcuts (interval index aligns with left node) *)
      let xl = x.{i-1} in
      let xc = x.{i} in
      let xr = x.{i+1} in

      (* compute entries of all Jacobian rows at node i *)
      RealArray.fill lu 0.0;
      RealArray.fill lv 0.0;
      RealArray.fill lw 0.0;

      (* first compute dependence on values to left and center *)

      (* compute diffusion Jacobian components *)

      (* L_u = -du * u_x * chiR_x *)
      (*   dL_u/dul   *)
      lu.{idx 0 0} <- (-.du)
                      *. quad(1.0,1.0,1.0,xl,xc)
                      *. chiL_x(xl,xc)
                      *. chiR_x(xl,xc);
      (*   dL_u/duc   *)
      lu.{idx 0 1} <- (-.du)
                      *. quad(1.0,1.0,1.0,xl,xc)
                      *. chiR_x(xl,xc)
                      *. chiR_x(xl,xc);

      (* L_v = -dv * v_x * chiR_x *)
      (*   dL_v/dvl   *)
      lv.{idx 1 0} <- (-.dv)
                      *. quad(1.0,1.0,1.0,xl,xc)
                      *. chiL_x(xl,xc)
                      *. chiR_x(xl,xc);
      (*   dL_v/dvc   *)
      lv.{idx 1 1} <- (-.dv)
                      *. quad(1.0,1.0,1.0,xl,xc)
                      *. chiR_x(xl,xc)
                      *. chiR_x(xl,xc);

      (* L_w =  -dw * w_x * chiR_x *)
      (*   dL_w/dwl   *)
      lw.{idx 2 0} <- (-.dw)
                      *. quad(1.0,1.0,1.0,xl,xc)
                      *. chiL_x(xl,xc)
                      *. chiR_x(xl,xc);
      (*   dL_w/dwc   *)
      lw.{idx 2 1} <- (-.dw)
                      *. quad(1.0,1.0,1.0,xl,xc)
                      *. chiR_x(xl,xc)
                      *. chiR_x(xl,xc);

      (* second compute dependence on values to center and right *)

      (* compute diffusion Jacobian components *)

      (* L_u = -du * u_x * chiL_x *)
      (*    dL_u/duc    *)
      lu.{idx 0 1} <- lu.{idx 0 1}
                      +. (-.du)
                         *. quad(1.0,1.0,1.0,xc,xr)
                         *. chiL_x(xc,xr)
                         *. chiL_x(xc,xr);

      (*    dL_u/dur    *)
      lu.{idx 0 2} <- lu.{idx 0 2}
                      +. (-.du)
                         *. quad(1.0,1.0,1.0,xc,xr)
                         *. chiL_x(xc,xr)
                         *. chiR_x(xc,xr);

      (* L_v = -dv * v_x * chiL_x *)
      (*    dL_v/dvc    *)
      lv.{idx 1 1} <- lv.{idx 1 1}
                      +. (-.dv)
                         *. quad(1.0,1.0,1.0,xc,xr)
                         *. chiL_x(xc,xr)
                         *. chiL_x(xc,xr);

      (*    dL_v/dvr    *)
      lv.{idx 1 2} <- lv.{idx 1 2}
                      +. (-.dv)
                         *. quad(1.0,1.0,1.0,xc,xr)
                         *. chiL_x(xc,xr)
                         *. chiR_x(xc,xr);

      (* L_w =  -dw * w_x * chiL_x *)
      (*    dL_w/dwc    *)
      lw.{idx 2 1} <- lw.{idx 2 1}
                      +. (-.dw)
                         *. quad(1.0,1.0,1.0,xc,xr)
                         *. chiL_x(xc,xr)
                         *. chiL_x(xc,xr);

      (*    dL_w/dwr    *)
      lw.{idx 2 2} <- lw.{idx 2 2}
                      +. (-.dw)
                         *. quad(1.0,1.0,1.0,xc,xr)
                         *. chiL_x(xc,xr)
                         *. chiR_x(xc,xr);

      (* insert Jacobian entries into CSR matrix structure *)

      (* Lu row *)
      rowptrs.{idx i 0} <- Index.of_int !nz;

      ldata.{!nz} <- lu.{idx 0 0};
      ldata.{!nz+1} <- lu.{idx 1 0};
      ldata.{!nz+2} <- lu.{idx 2 0};
      colinds.{!nz} <- iidx (i-1) 0;
      colinds.{!nz+1} <- iidx (i-1) 1;
      colinds.{!nz+2} <- iidx (i-1) 2;
      nz := !nz + 3;

      ldata.{!nz} <- lu.{idx 0 1};
      ldata.{!nz+1} <- lu.{idx 1 1};
      ldata.{!nz+2} <- lu.{idx 2 1};
      colinds.{!nz} <- iidx i 0;
      colinds.{!nz+1} <- iidx i 1;
      colinds.{!nz+2} <- iidx i 2;
      nz := !nz + 3;

      ldata.{!nz} <- lu.{idx 0 2};
      ldata.{!nz+1} <- lu.{idx 1 2};
      ldata.{!nz+2} <- lu.{idx 2 2};
      colinds.{!nz} <- iidx (i+1) 0;
      colinds.{!nz+1} <- iidx (i+1) 1;
      colinds.{!nz+2} <- iidx (i+1) 2;
      nz := !nz + 3;

      (* Lv row *)
      rowptrs.{idx i 1} <- Index.of_int !nz;

      ldata.{!nz} <- lv.{idx 0 0};
      ldata.{!nz+1} <- lv.{idx 1 0};
      ldata.{!nz+2} <- lv.{idx 2 0};
      colinds.{!nz} <- iidx (i-1) 0;
      colinds.{!nz+1} <- iidx (i-1) 1;
      colinds.{!nz+2} <- iidx (i-1) 2;
      nz := !nz + 3;

      ldata.{!nz} <- lv.{idx 0 1};
      ldata.{!nz+1} <- lv.{idx 1 1};
      ldata.{!nz+2} <- lv.{idx 2 1};
      colinds.{!nz} <- iidx i 0;
      colinds.{!nz+1} <- iidx i 1;
      colinds.{!nz+2} <- iidx i 2;
      nz:= !nz + 3;

      ldata.{!nz} <- lv.{idx 0 2};
      ldata.{!nz+1} <- lv.{idx 1 2};
      ldata.{!nz+2} <- lv.{idx 2 2};
      colinds.{!nz} <- iidx (i+1) 0;
      colinds.{!nz+1} <- iidx (i+1) 1;
      colinds.{!nz+2} <- iidx (i+1) 2;
      nz := !nz + 3;

      (* Lw row *)
      rowptrs.{idx i 2} <- Index.of_int !nz;

      ldata.{!nz} <- lw.{idx 0 0};
      ldata.{!nz+1} <- lw.{idx 1 0};
      ldata.{!nz+2} <- lw.{idx 2 0};
      colinds.{!nz} <- iidx (i-1) 0;
      colinds.{!nz+1} <- iidx (i-1) 1;
      colinds.{!nz+2} <- iidx (i-1) 2;
      nz := !nz + 3;

      ldata.{!nz} <- lw.{idx 0 1};
      ldata.{!nz+1} <- lw.{idx 1 1};
      ldata.{!nz+2} <- lw.{idx 2 1};
      colinds.{!nz} <- iidx i 0;
      colinds.{!nz+1} <- iidx i 1;
      colinds.{!nz+2} <- iidx i 2;
      nz := !nz + 3;

      ldata.{!nz} <- lw.{idx 0 2};
      ldata.{!nz+1} <- lw.{idx 1 2};
      ldata.{!nz+2} <- lw.{idx 2 2};
      colinds.{!nz} <- iidx (i+1) 0;
      colinds.{!nz+1} <- iidx (i+1) 1;
      colinds.{!nz+2} <- iidx (i+1) 2;
      nz := !nz + 3
    done;

    (* Dirichlet boundary at right *)
    rowptrs.{idx (n-1) 0} <- Index.of_int !nz;
    rowptrs.{idx (n-1) 1} <- Index.of_int !nz;
    rowptrs.{idx (n-1) 2} <- Index.of_int !nz;

    (* signal end of data *)
    rowptrs.{(idx (n-1) 2) + 1} <- Index.of_int !nz
  (* }}} *)

  (* Routine to compute the Jacobian matrix from R(y) *)
  let reaction_jac { n; ep; x } (y : RealArray.t) jac = (* {{{ *)
    let iidx x v = Index.of_int (idx x v) in
    let nz = ref 0 in
    (* set local variables *)
    let ju = RealArray.make 9 0.0 in
    let jv = RealArray.make 9 0.0 in
    let jw = RealArray.make 9 0.0 in

    (* clear out matrix *)
    Matrix.Sparse.set_to_zero jac;
    let colinds, rowptrs, j = Matrix.Sparse.unwrap jac in

    (* Dirichlet boundary at left *)
    rowptrs.{idx 0 0} <- Index.of_int !nz;
    rowptrs.{idx 0 1} <- Index.of_int !nz;
    rowptrs.{idx 0 2} <- Index.of_int !nz;

    (* iterate over columns, filling in reaction Jacobian *)
    for i = 1 to n - 2 do
      (* set nodal value shortcuts (interval index aligns with left node) *)
      let xl = x.{i-1} in
      let ul = y.{idx (i-1) 0} in
      let vl = y.{idx (i-1) 1} in
      let wl = y.{idx (i-1) 2} in
      let xc = x.{i} in
      let uc = y.{idx (i) 0} in
      let vc = y.{idx (i) 1} in
      let wc = y.{idx (i) 2} in
      let xr = x.{i+1} in
      let ur = y.{idx (i+1) 0} in
      let vr = y.{idx (i+1) 1} in
      let wr = y.{idx (i+1) 2} in

      (* compute entries of all Jacobian rows at node i *)
      RealArray.fill ju 0.0;
      RealArray.fill jv 0.0;
      RealArray.fill jw 0.0;
      (* first compute dependence on values to left and center *)

      (* evaluate relevant variables in left subinterval *)
      let u1 = eval(ul, uc, xl, xc, x1(xl,xc)) in
      let v1 = eval(vl, vc, xl, xc, x1(xl,xc)) in
      let w1 = eval(wl, wc, xl, xc, x1(xl,xc)) in
      let u2 = eval(ul, uc, xl, xc, x2(xl,xc)) in
      let v2 = eval(vl, vc, xl, xc, x2(xl,xc)) in
      let w2 = eval(wl, wc, xl, xc, x2(xl,xc)) in
      let u3 = eval(ul, uc, xl, xc, x3(xl,xc)) in
      let v3 = eval(vl, vc, xl, xc, x3(xl,xc)) in
      let w3 = eval(wl, wc, xl, xc, x3(xl,xc)) in

      let dQdf1 = quad(1.0, 0.0, 0.0, xl, xc) in
      let dQdf2 = quad(0.0, 1.0, 0.0, xl, xc) in
      let dQdf3 = quad(0.0, 0.0, 1.0, xl, xc) in

      let chiL1 = chiL(xl, xc, x1(xl,xc)) in
      let chiL2 = chiL(xl, xc, x2(xl,xc)) in
      let chiL3 = chiL(xl, xc, x3(xl,xc)) in
      let chiR1 = chiR(xl, xc, x1(xl,xc)) in
      let chiR2 = chiR(xl, xc, x2(xl,xc)) in
      let chiR3 = chiR(xl, xc, x3(xl,xc)) in

      (* compute reaction Jacobian components *)

      (* R_u = (a - (w+OnE)*u + v*u*u) *)
      (*   dR_u/dul   *)
      let df1 = (-.(w1+.1.0) +. 2.0*.v1*.u1) *. chiL1 *. chiR1 in
      let df2 = (-.(w2+.1.0) +. 2.0*.v2*.u2) *. chiL2 *. chiR2 in
      let df3 = (-.(w3+.1.0) +. 2.0*.v3*.u3) *. chiL3 *. chiR3 in
      ju.{idx 0 0} <- ju.{idx 0 0} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*   dR_u/duc   *)
      let df1 = (-.(w1+.1.0) +. 2.0*.v1*.u1) *. chiR1 *. chiR1 in
      let df2 = (-.(w2+.1.0) +. 2.0*.v2*.u2) *. chiR2 *. chiR2 in
      let df3 = (-.(w3+.1.0) +. 2.0*.v3*.u3) *. chiR3 *. chiR3 in
      ju.{idx 0 1} <- ju.{idx 0 1} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*   dR_u/dvl   *)
      let df1 = (u1*.u1) *. chiL1 *. chiR1 in
      let df2 = (u2*.u2) *. chiL2 *. chiR2 in
      let df3 = (u3*.u3) *. chiL3 *. chiR3 in
      ju.{idx 1 0} <- ju.{idx 1 0} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*   dR_u/dvc   *)
      let df1 = (u1*.u1) *. chiR1 *. chiR1 in
      let df2 = (u2*.u2) *. chiR2 *. chiR2 in
      let df3 = (u3*.u3) *. chiR3 *. chiR3 in
      ju.{idx 1 1} <- ju.{idx 1 1} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*   dR_u/dwl   *)
      let df1 = (-.u1) *. chiL1 *. chiR1 in
      let df2 = (-.u2) *. chiL2 *. chiR2 in
      let df3 = (-.u3) *. chiL3 *. chiR3 in
      ju.{idx 2 0} <- ju.{idx 2 0} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*   dR_u/dwc   *)
      let df1 = (-.u1) *. chiR1 *. chiR1 in
      let df2 = (-.u2) *. chiR2 *. chiR2 in
      let df3 = (-.u3) *. chiR3 *. chiR3 in
      ju.{idx 2 1} <- ju.{idx 2 1} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (* R_v = (w*u - v*u*u) *)
      (*   dR_v/dul   *)
      let df1 = (w1 -. 2.0*.v1*.u1) *. chiL1 *. chiR1 in
      let df2 = (w2 -. 2.0*.v2*.u2) *. chiL2 *. chiR2 in
      let df3 = (w3 -. 2.0*.v3*.u3) *. chiL3 *. chiR3 in
      jv.{idx 0 0} <- jv.{idx 0 0} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*   dR_v/duc   *)
      let df1 = (w1 -. 2.0*.v1*.u1) *. chiR1 *. chiR1 in
      let df2 = (w2 -. 2.0*.v2*.u2) *. chiR2 *. chiR2 in
      let df3 = (w3 -. 2.0*.v3*.u3) *. chiR3 *. chiR3 in
      jv.{idx 0 1} <- jv.{idx 0 1} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*   dR_v/dvl   *)
      let df1 = (-.u1*.u1) *. chiL1 *. chiR1 in
      let df2 = (-.u2*.u2) *. chiL2 *. chiR2 in
      let df3 = (-.u3*.u3) *. chiL3 *. chiR3 in
      jv.{idx 1 0} <- jv.{idx 1 0} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*   dR_v/dvc   *)
      let df1 = (-.u1*.u1) *. chiR1 *. chiR1 in
      let df2 = (-.u2*.u2) *. chiR2 *. chiR2 in
      let df3 = (-.u3*.u3) *. chiR3 *. chiR3 in
      jv.{idx 1 1} <- jv.{idx 1 1} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*   dR_v/dwl   *)
      let df1 = (u1) *. chiL1 *. chiR1 in
      let df2 = (u2) *. chiL2 *. chiR2 in
      let df3 = (u3) *. chiL3 *. chiR3 in
      jv.{idx 2 0} <- jv.{idx 2 0} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*   dR_v/dwc   *)
      let df1 = (u1) *. chiR1 *. chiR1 in
      let df2 = (u2) *. chiR2 *. chiR2 in
      let df3 = (u3) *. chiR3 *. chiR3 in
      jv.{idx 2 1} <- jv.{idx 2 1} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (* R_w = ((b-.w)/ep -. w*u) *)
      (*   dR_w/dul   *)
      let df1 = (-.w1) *. chiL1 *. chiR1 in
      let df2 = (-.w2) *. chiL2 *. chiR2 in
      let df3 = (-.w3) *. chiL3 *. chiR3 in
      jw.{idx 0 0} <- jw.{idx 0 0} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*   dR_w/duc   *)
      let df1 = (-.w1) *. chiR1 *. chiR1 in
      let df2 = (-.w2) *. chiR2 *. chiR2 in
      let df3 = (-.w3) *. chiR3 *. chiR3 in
      jw.{idx 0 1} <- jw.{idx 0 1} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*   dR_w/dwl   *)
      let df1 = (-1.0/.ep -. u1) *. chiL1 *. chiR1 in
      let df2 = (-1.0/.ep -. u2) *. chiL2 *. chiR2 in
      let df3 = (-1.0/.ep -. u3) *. chiL3 *. chiR3 in
      jw.{idx 2 0} <- jw.{idx 2 0} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*   dR_w/dwc   *)
      let df1 = (-1.0/.ep -. u1) *. chiR1 *. chiR1 in
      let df2 = (-1.0/.ep -. u2) *. chiR2 *. chiR2 in
      let df3 = (-1.0/.ep -. u3) *. chiR3 *. chiR3 in
      jw.{idx 2 1} <- jw.{idx 2 1} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (* second compute dependence on values to center and right *)

      (* evaluate relevant variables in right subinterval *)
      let u1 = eval(uc, ur, xc, xr, x1(xc,xr)) in
      let v1 = eval(vc, vr, xc, xr, x1(xc,xr)) in
      let w1 = eval(wc, wr, xc, xr, x1(xc,xr)) in
      let u2 = eval(uc, ur, xc, xr, x2(xc,xr)) in
      let v2 = eval(vc, vr, xc, xr, x2(xc,xr)) in
      let w2 = eval(wc, wr, xc, xr, x2(xc,xr)) in
      let u3 = eval(uc, ur, xc, xr, x3(xc,xr)) in
      let v3 = eval(vc, vr, xc, xr, x3(xc,xr)) in
      let w3 = eval(wc, wr, xc, xr, x3(xc,xr)) in

      let dQdf1 = quad(1.0, 0.0, 0.0, xc, xr) in
      let dQdf2 = quad(0.0, 1.0, 0.0, xc, xr) in
      let dQdf3 = quad(0.0, 0.0, 1.0, xc, xr) in

      let chiL1 = chiL(xc, xr, x1(xc,xr)) in
      let chiL2 = chiL(xc, xr, x2(xc,xr)) in
      let chiL3 = chiL(xc, xr, x3(xc,xr)) in
      let chiR1 = chiR(xc, xr, x1(xc,xr)) in
      let chiR2 = chiR(xc, xr, x2(xc,xr)) in
      let chiR3 = chiR(xc, xr, x3(xc,xr)) in

      (* compute reaction Jacobian comp1.0nts *)

      (* R_u = (a - (w+1.0)*u + v*u*u) *)
      (*    dR_u/duc    *)
      let df1 = (-.(w1+.1.0) +. 2.0*.v1*.u1) *. chiL1 *. chiL1 in
      let df2 = (-.(w2+.1.0) +. 2.0*.v2*.u2) *. chiL2 *. chiL2 in
      let df3 = (-.(w3+.1.0) +. 2.0*.v3*.u3) *. chiL3 *. chiL3 in
      ju.{idx 0 0} <- ju.{idx 0 0} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*    dR_u/dur    *)
      let df1 = (-.(w1+.1.0) +. 2.0*.v1*.u1) *. chiL1 *. chiR1 in
      let df2 = (-.(w2+.1.0) +. 2.0*.v2*.u2) *. chiL2 *. chiR2 in
      let df3 = (-.(w3+.1.0) +. 2.0*.v3*.u3) *. chiL3 *. chiR3 in
      ju.{idx 0 1} <- ju.{idx 0 1} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*    dR_u/dvc    *)
      let df1 = (u1*.u1) *. chiL1 *. chiL1 in
      let df2 = (u2*.u2) *. chiL2 *. chiL2 in
      let df3 = (u3*.u3) *. chiL3 *. chiL3 in
      ju.{idx 1 1} <- ju.{idx 1 1} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*    dR_u/dvr    *)
      let df1 = (u1*.u1) *. chiL1 *. chiR1 in
      let df2 = (u2*.u2) *. chiL2 *. chiR2 in
      let df3 = (u3*.u3) *. chiL3 *. chiR3 in
      ju.{idx 1 2} <- ju.{idx 1 2} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*    dR_u/dwc   *)
      let df1 = (-.u1) *. chiL1 *. chiL1 in
      let df2 = (-.u2) *. chiL2 *. chiL2 in
      let df3 = (-.u3) *. chiL3 *. chiL3 in
      ju.{idx 2 1} <- ju.{idx 2 1} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*    dR_u/dwr   *)
      let df1 = (-.u1) *. chiL1 *. chiR1 in
      let df2 = (-.u2) *. chiL2 *. chiR2 in
      let df3 = (-.u3) *. chiL3 *. chiR3 in
      ju.{idx 2 2} <- ju.{idx 2 2} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;


      (* R_v = (w*u - v*u*u) *)
      (*    dR_v/duc     *)
      let df1 = (w1 -. 2.0*.v1*.u1) *. chiL1 *. chiL1 in
      let df2 = (w2 -. 2.0*.v2*.u2) *. chiL2 *. chiL2 in
      let df3 = (w3 -. 2.0*.v3*.u3) *. chiL3 *. chiL3 in
      jv.{idx 0 1} <- jv.{idx 0 1} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*    dR_v/dur     *)
      let df1 = (w1 -. 2.0*.v1*.u1) *. chiL1 *. chiR1 in
      let df2 = (w2 -. 2.0*.v2*.u2) *. chiL2 *. chiR2 in
      let df3 = (w3 -. 2.0*.v3*.u3) *. chiL3 *. chiR3 in
      jv.{idx 0 2} <- jv.{idx 0 2} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*    dR_v/dvc     *)
      let df1 = (-.u1*.u1) *. chiL1 *. chiL1 in
      let df2 = (-.u2*.u2) *. chiL2 *. chiL2 in
      let df3 = (-.u3*.u3) *. chiL3 *. chiL3 in
      jv.{idx 1 1} <- jv.{idx 1 1} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*    dR_v/dvr    *)
      let df1 = (-.u1*.u1) *. chiL1 *. chiR1 in
      let df2 = (-.u2*.u2) *. chiL2 *. chiR2 in
      let df3 = (-.u3*.u3) *. chiL3 *. chiR3 in
      jv.{idx 1 2} <- jv.{idx 1 2} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*    dR_v/dwc    *)
      let df1 = (u1) *. chiL1 *. chiL1 in
      let df2 = (u2) *. chiL2 *. chiL2 in
      let df3 = (u3) *. chiL3 *. chiL3 in
      jv.{idx 2 1} <- jv.{idx 2 1} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*    dR_v/dwr    *)
      let df1 = (u1) *. chiL1 *. chiR1 in
      let df2 = (u2) *. chiL2 *. chiR2 in
      let df3 = (u3) *. chiL3 *. chiR3 in
      jv.{idx 2 2} <- jv.{idx 2 2} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;


      (* R_w = ((b-w)/ep -. w*u) *)
      (*    dR_w/duc    *)
      let df1 = (-.w1) *. chiL1 *. chiL1 in
      let df2 = (-.w2) *. chiL2 *. chiL2 in
      let df3 = (-.w3) *. chiL3 *. chiL3 in
      jw.{idx 0 1} <- jw.{idx 0 1} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*    dR_w/dur    *)
      let df1 = (-.w1) *. chiL1 *. chiR1 in
      let df2 = (-.w2) *. chiL2 *. chiR2 in
      let df3 = (-.w3) *. chiL3 *. chiR3 in
      jw.{idx 0 2} <- jw.{idx 0 2} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*    dR_w/dwc    *)
      let df1 = (-.1.0/.ep -. u1) *. chiL1 *. chiL1 in
      let df2 = (-.1.0/.ep -. u2) *. chiL2 *. chiL2 in
      let df3 = (-.1.0/.ep -. u3) *. chiL3 *. chiL3 in
      jw.{idx 2 1} <- jw.{idx 2 1} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (*    dR_w/dwr    *)
      let df1 = (-.1.0/.ep -. u1) *. chiL1 *. chiR1 in
      let df2 = (-.1.0/.ep -. u2) *. chiL2 *. chiR2 in
      let df3 = (-.1.0/.ep -. u3) *. chiL3 *. chiR3 in
      jw.{idx 2 2} <- jw.{idx 2 2} +. dQdf1*.df1 +. dQdf2*.df2 +. dQdf3*.df3;

      (* insert Jacobian entries into CSR matrix structure *)

      (* Ju row *)
      rowptrs.{idx (i) 0} <- Index.of_int !nz;

      j.{!nz} <- ju.{idx 0 0};
      j.{!nz+1} <- ju.{idx 1 0};
      j.{!nz+2} <- ju.{idx 2 0};
      colinds.{!nz} <- iidx (i-1) 0;
      colinds.{!nz+1} <- iidx (i-1) 1;
      colinds.{!nz+2} <- iidx (i-1) 2;
      nz := !nz + 3;

      j.{!nz} <- ju.{idx 0 1};
      j.{!nz+1} <- ju.{idx 1 1};
      j.{!nz+2} <- ju.{idx 2 1};
      colinds.{!nz} <- iidx (i) 0;
      colinds.{!nz+1} <- iidx (i) 1;
      colinds.{!nz+2} <- iidx (i) 2;
      nz := !nz + 3;

      j.{!nz} <- ju.{idx 0 2};
      j.{!nz+1} <- ju.{idx 1 2};
      j.{!nz+2} <- ju.{idx 2 2};
      colinds.{!nz} <- iidx (i+1) 0;
      colinds.{!nz+1} <- iidx (i+1) 1;
      colinds.{!nz+2} <- iidx (i+1) 2;
      nz := !nz + 3;

      (* Jv row *)
      rowptrs.{idx (i) 1} <- Index.of_int !nz;

      j.{!nz} <- jv.{idx 0 0};
      j.{!nz+1} <- jv.{idx 1 0};
      j.{!nz+2} <- jv.{idx 2 0};
      colinds.{!nz} <- iidx (i-1) 0;
      colinds.{!nz+1} <- iidx (i-1) 1;
      colinds.{!nz+2} <- iidx (i-1) 2;
      nz := !nz + 3;

      j.{!nz} <- jv.{idx 0 1};
      j.{!nz+1} <- jv.{idx 1 1};
      j.{!nz+2} <- jv.{idx 2 1};
      colinds.{!nz} <- iidx (i) 0;
      colinds.{!nz+1} <- iidx (i) 1;
      colinds.{!nz+2} <- iidx (i) 2;
      nz := !nz + 3;

      j.{!nz} <- jv.{idx 0 2};
      j.{!nz+1} <- jv.{idx 1 2};
      j.{!nz+2} <- jv.{idx 2 2};
      colinds.{!nz} <- iidx (i+1) 0;
      colinds.{!nz+1} <- iidx (i+1) 1;
      colinds.{!nz+2} <- iidx (i+1) 2;
      nz := !nz + 3;

      (* Jw row *)
      rowptrs.{idx (i) 2} <- Index.of_int !nz;

      j.{!nz} <- jw.{idx 0 0};
      j.{!nz+1} <- jw.{idx 1 0};
      j.{!nz+2} <- jw.{idx 2 0};
      colinds.{!nz} <- iidx (i-1) 0;
      colinds.{!nz+1} <- iidx (i-1) 1;
      colinds.{!nz+2} <- iidx (i-1) 2;
      nz := !nz + 3;

      j.{!nz} <- jw.{idx 0 1};
      j.{!nz+1} <- jw.{idx 1 1};
      j.{!nz+2} <- jw.{idx 2 1};
      colinds.{!nz} <- iidx (i) 0;
      colinds.{!nz+1} <- iidx (i) 1;
      colinds.{!nz+2} <- iidx (i) 2;
      nz := !nz + 3;

      j.{!nz} <- jw.{idx 0 2};
      j.{!nz+1} <- jw.{idx 1 2};
      j.{!nz+2} <- jw.{idx 2 2};
      colinds.{!nz} <- iidx (i+1) 0;
      colinds.{!nz+1} <- iidx (i+1) 1;
      colinds.{!nz+2} <- iidx (i+1) 2;
      nz := !nz + 3
    done;

    (* Dirichlet boundary at right *)
    rowptrs.{idx (n-1) 0} <- Index.of_int !nz;
    rowptrs.{idx (n-1) 1} <- Index.of_int !nz;
    rowptrs.{idx (n-1) 2} <- Index.of_int !nz;

    (* signal end of data *)
    rowptrs.{idx (n-1) 2+1} <- Index.of_int !nz
  (* }}} *)

  (* Routine to compute the mass matrix multiplying y_t. *)
  let mass_matrix { n; x } _ _ m = (* {{{ *)
    let iidx x v = Index.of_int (idx x v) in
    let nz = ref 0 in
    let rows, cols = Matrix.Sparse.size m in
    let nnz, _ = Matrix.Sparse.dims m in
    (* check that vector/matrix dimensions match up *)
    let neq = 3 * n in
    if (rows != neq) || (cols != neq) || (nnz != 15 * neq) then
      failwith "MassMatrix calculation error: matrix is wrong size!\n";

    (* clear out matrix *)
    Matrix.Sparse.set_to_zero m;
    let colinds, rowptrs, m = Matrix.Sparse.unwrap m in

    (* iterate through nodes, filling in matrix by rows *)
    for i = 0 to n - 1 do
      (* set booleans to determine whether intervals exist on the left/right *)
      let left  = not (i = 0) in
      let right = not (i = (n - 1)) in

      (* set nodal value shortcuts (interval index aligns with left node) *)
      let xc = x.{i} in

      (* compute entries of all mass matrix rows at node ix *)
      let ml = ref 0.0 in
      let mc = ref 0.0 in
      let mr = ref 0.0 in

      (* first compute dependence on values to left and center *)
      if left then begin
        let xl = x.{i-1} in
        let chiL1 = chiL(xl, xc, x1(xl,xc)) in
        let chiL2 = chiL(xl, xc, x2(xl,xc)) in
        let chiL3 = chiL(xl, xc, x3(xl,xc)) in
        let chiR1 = chiR(xl, xc, x1(xl,xc)) in
        let chiR2 = chiR(xl, xc, x2(xl,xc)) in
        let chiR3 = chiR(xl, xc, x3(xl,xc)) in
        ml := !ml +. quad(chiL1*.chiR1, chiL2*.chiR2, chiL3*.chiR3, xl, xc);
        mc := !mc +. quad(chiR1*.chiR1, chiR2*.chiR2, chiR3*.chiR3, xl, xc);
      end;

      (* second compute dependence on values to center and right *)
      if right then begin
        let xr = x.{i+1} in
        let chiL1 = chiL(xc, xr, x1(xc,xr)) in
        let chiL2 = chiL(xc, xr, x2(xc,xr)) in
        let chiL3 = chiL(xc, xr, x3(xc,xr)) in
        let chiR1 = chiR(xc, xr, x1(xc,xr)) in
        let chiR2 = chiR(xc, xr, x2(xc,xr)) in
        let chiR3 = chiR(xc, xr, x3(xc,xr)) in
        mc := !mc +. quad(chiL1*.chiL1, chiL2*.chiL2, chiL3*.chiL3, xc, xr);
        mr := !mr +. quad(chiL1*.chiR1, chiL2*.chiR2, chiL3*.chiR3, xc, xr);
      end;

      (* insert mass matrix entires into CSR matrix structure *)

      (* u row *)
      rowptrs.{idx (i) 0} <- Index.of_int !nz;
      if left then begin
        m.{!nz} <- !ml;
        colinds.{!nz} <- iidx (i-1) 0;
        incr nz
      end;
      m.{!nz} <- !mc;
      colinds.{!nz} <- iidx i 0;
      incr nz;
      if right then begin
        m.{!nz} <- !mr;
        colinds.{!nz} <- iidx (i+1) 0;
        incr nz
      end;

      (* v row *)
      rowptrs.{idx (i) 1} <- Index.of_int !nz;
      if left then begin
        m.{!nz} <- !ml;
        colinds.{!nz} <- iidx (i-1) 1;
        incr nz
      end;
      m.{!nz} <- !mc;
      colinds.{!nz} <- iidx (i) 1;
      incr nz;
      if right then begin
        m.{!nz} <- !mr;
        colinds.{!nz} <- iidx (i+1) 1;
        incr nz
      end;

      (* w row *)
      rowptrs.{idx (i) 2} <- Index.of_int !nz;
      if left then begin
        m.{!nz} <- !ml;
        colinds.{!nz} <- iidx (i-1) 2;
        incr nz;
      end;
      m.{!nz} <- !mc;
      colinds.{!nz} <- iidx (i) 2;
      incr nz;
      if right then begin
        m.{!nz} <- !mr;
        colinds.{!nz} <- iidx (i+1) 2;
        incr nz
      end
    done;

    (* signal end of data *)
    rowptrs.{(idx (n-1) 2)+1} <- Index.of_int !nz
  (* }}} *)

end (* }}} *)

module Problem (I : sig
    type smat

    val newmat : ?nnz:int -> int -> (smat, 'nk) Matrix.sparse
    val makemat : int -> int -> int -> smat Matrix.Sparse.t

    val laplace_matrix : user_data -> smat Matrix.Sparse.t -> unit
    val reaction_jac   : user_data -> RealArray.t -> smat Matrix.Sparse.t -> unit
    val mass_matrix    : user_data -> 'a -> 'b -> smat Matrix.Sparse.t -> unit
  end) =
struct (* {{{ *)

  (* Routine to compute the reaction portion of the ODE RHS function f(t,y). *)
  let f_rx { n; a; b; ep; x } t (y : RealArray.t) (ydot : RealArray.t) =
    (* iterate over intervals, filling in residual function *)
    for i=0 to n-1-1 do
      (* set booleans to determine whether equations exist on the left/right *)
      let left  = i <> 0 in
      let right = i <> n - 2 in

      (* set nodal value shortcuts (interval index aligns with left node) *)
      let ul = y.{idx i 0} in
      let vl = y.{idx i 1} in
      let wl = y.{idx i 2} in
      let ur = y.{idx (i+1) 0} in
      let vr = y.{idx (i+1) 1} in
      let wr = y.{idx (i+1) 2} in

      (* set mesh shortcuts *)
      let xl = x.{i} in
      let xr = x.{i+1} in

      (* evaluate R(y) on this subinterval *)
      (*    left test function *)
      if left then begin
        (*  u *)
        let u = eval(ul,ur,xl,xr,x1(xl,xr)) in
        let v = eval(vl,vr,xl,xr,x1(xl,xr)) in
        let w = eval(wl,wr,xl,xr,x1(xl,xr)) in
        let f1 = (a -. (w+.1.0)*.u +. v*.u*.u) *. chiL(xl,xr,x1(xl,xr)) in
        let u = eval(ul,ur,xl,xr,x2(xl,xr)) in
        let v = eval(vl,vr,xl,xr,x2(xl,xr)) in
        let w = eval(wl,wr,xl,xr,x2(xl,xr)) in
        let f2 = (a -. (w+.1.0)*.u +. v*.u*.u) *. chiL(xl,xr,x2(xl,xr)) in
        let u = eval(ul,ur,xl,xr,x3(xl,xr)) in
        let v = eval(vl,vr,xl,xr,x3(xl,xr)) in
        let w = eval(wl,wr,xl,xr,x3(xl,xr)) in
        let f3 = (a -. (w+.1.0)*.u +. v*.u*.u) *. chiL(xl,xr,x3(xl,xr)) in
        ydot.{idx i 0} <- ydot.{idx i 0} +. quad(f1,f2,f3,xl,xr);

        (*  v *)
        let u = eval(ul,ur,xl,xr,x1(xl,xr)) in
        let v = eval(vl,vr,xl,xr,x1(xl,xr)) in
        let w = eval(wl,wr,xl,xr,x1(xl,xr)) in
        let f1 = (w*.u -. v*.u*.u) *. chiL(xl,xr,x1(xl,xr)) in
        let u = eval(ul,ur,xl,xr,x2(xl,xr)) in
        let v = eval(vl,vr,xl,xr,x2(xl,xr)) in
        let w = eval(wl,wr,xl,xr,x2(xl,xr)) in
        let f2 = (w*.u -. v*.u*.u) *. chiL(xl,xr,x2(xl,xr)) in
        let u = eval(ul,ur,xl,xr,x3(xl,xr)) in
        let v = eval(vl,vr,xl,xr,x3(xl,xr)) in
        let w = eval(wl,wr,xl,xr,x3(xl,xr)) in
        let f3 = (w*.u -. v*.u*.u) *. chiL(xl,xr,x3(xl,xr)) in
        ydot.{idx i 1} <- ydot.{idx i 1} +. quad(f1,f2,f3,xl,xr);

        (*  w *)
        let u = eval(ul,ur,xl,xr,x1(xl,xr)) in
        (* let v = eval(vl,vr,xl,xr,x1(xl,xr)) in *)
        let w = eval(wl,wr,xl,xr,x1(xl,xr)) in
        let f1 = ((b-.w)/.ep -. w*.u) *. chiL(xl,xr,x1(xl,xr)) in
        let u = eval(ul,ur,xl,xr,x2(xl,xr)) in
        (* let v = eval(vl,vr,xl,xr,x2(xl,xr)) in *)
        let w = eval(wl,wr,xl,xr,x2(xl,xr)) in
        let f2 = ((b-.w)/.ep -. w*.u) *. chiL(xl,xr,x2(xl,xr)) in
        let u = eval(ul,ur,xl,xr,x3(xl,xr)) in
        (* let v = eval(vl,vr,xl,xr,x3(xl,xr)) in *)
        let w = eval(wl,wr,xl,xr,x3(xl,xr)) in
        let f3 = ((b-.w)/.ep -. w*.u) *. chiL(xl,xr,x3(xl,xr)) in
        ydot.{idx i 2} <- ydot.{idx i 2} +. quad(f1,f2,f3,xl,xr)
      end;
      (*    right test function *)
      if right then begin
        (*  u *)
        let u = eval(ul,ur,xl,xr,x1(xl,xr)) in
        let v = eval(vl,vr,xl,xr,x1(xl,xr)) in
        let w = eval(wl,wr,xl,xr,x1(xl,xr)) in
        let f1 = (a -. (w+.1.0)*.u +. v*.u*.u) *. chiR(xl,xr,x1(xl,xr)) in
        let u = eval(ul,ur,xl,xr,x2(xl,xr)) in
        let v = eval(vl,vr,xl,xr,x2(xl,xr)) in
        let w = eval(wl,wr,xl,xr,x2(xl,xr)) in
        let f2 = (a -. (w+.1.0)*.u +. v*.u*.u) *. chiR(xl,xr,x2(xl,xr)) in
        let u = eval(ul,ur,xl,xr,x3(xl,xr)) in
        let v = eval(vl,vr,xl,xr,x3(xl,xr)) in
        let w = eval(wl,wr,xl,xr,x3(xl,xr)) in
        let f3 = (a -. (w+.1.0)*.u +. v*.u*.u) *. chiR(xl,xr,x3(xl,xr)) in
        ydot.{idx (i+1) 0} <- ydot.{idx (i+1) 0} +. quad(f1,f2,f3,xl,xr);

        (*  v *)
        let u = eval(ul,ur,xl,xr,x1(xl,xr)) in
        let v = eval(vl,vr,xl,xr,x1(xl,xr)) in
        let w = eval(wl,wr,xl,xr,x1(xl,xr)) in
        let f1 = (w*.u -. v*.u*.u) *. chiR(xl,xr,x1(xl,xr)) in
        let u = eval(ul,ur,xl,xr,x2(xl,xr)) in
        let v = eval(vl,vr,xl,xr,x2(xl,xr)) in
        let w = eval(wl,wr,xl,xr,x2(xl,xr)) in
        let f2 = (w*.u -. v*.u*.u) *. chiR(xl,xr,x2(xl,xr)) in
        let u = eval(ul,ur,xl,xr,x3(xl,xr)) in
        let v = eval(vl,vr,xl,xr,x3(xl,xr)) in
        let w = eval(wl,wr,xl,xr,x3(xl,xr)) in
        let f3 = (w*.u -. v*.u*.u) *. chiR(xl,xr,x3(xl,xr)) in
        ydot.{idx (i+1) 1} <- ydot.{idx (i+1) 1} +. quad(f1,f2,f3,xl,xr);

        (*  w *)
        let u = eval(ul,ur,xl,xr,x1(xl,xr)) in
        (* let v = eval(vl,vr,xl,xr,x1(xl,xr)) in *)
        let w = eval(wl,wr,xl,xr,x1(xl,xr)) in
        let f1 = ((b-.w)/.ep -. w*.u) *. chiR(xl,xr,x1(xl,xr)) in
        let u = eval(ul,ur,xl,xr,x2(xl,xr)) in
        (* let v = eval(vl,vr,xl,xr,x2(xl,xr)) in *)
        let w = eval(wl,wr,xl,xr,x2(xl,xr)) in
        let f2 = ((b-.w)/.ep -. w*.u) *. chiR(xl,xr,x2(xl,xr)) in
        let u = eval(ul,ur,xl,xr,x3(xl,xr)) in
        (* let v = eval(vl,vr,xl,xr,x3(xl,xr)) in *)
        let w = eval(wl,wr,xl,xr,x3(xl,xr)) in
        let f3 = ((b-.w)/.ep -. w*.u) *. chiR(xl,xr,x3(xl,xr)) in
        ydot.{idx (i+1) 2} <- ydot.{idx (i+1) 2} +. quad(f1,f2,f3,xl,xr);
      end
    done

  (* Routine to compute the diffusion portion of the ODE RHS function f(t,y). *)
  let f_diff { n; du; dv; dw; x } t (y : RealArray.t) (ydot : RealArray.t) =
    (* iterate over intervals, filling in residual function *)
    for i=0 to n-2 do
      (* set booleans to determine whether equations exist on the left/right *)
      let left  = i <> 0 in
      let right = i <> n - 2 in

      (* set nodal value shortcuts (interval index aligns with left node) *)
      let ul = y.{idx i 0} in
      let vl = y.{idx i 1} in
      let wl = y.{idx i 2} in
      let ur = y.{idx (i+1) 0} in
      let vr = y.{idx (i+1) 1} in
      let wr = y.{idx (i+1) 2} in

      (* set mesh shortcuts *)
      let xl = x.{i} in
      let xr = x.{i+1} in

      (* evaluate L*y on this subinterval
         NOTE: all f values are the same since constant on interval *)
      (*    left test function *)
      if left then begin
        (*  u *)
        let f1 = -.du *. eval_x(ul,ur,xl,xr) *. chiL_x(xl,xr) in
        ydot.{idx i 0} <- ydot.{idx i 0} +. quad(f1,f1,f1,xl,xr);

        (*  v *)
        let f1 = -.dv *. eval_x(vl,vr,xl,xr) *. chiL_x(xl,xr) in
        ydot.{idx i 1} <- ydot.{idx i 1} +. quad(f1,f1,f1,xl,xr);

        (*  w *)
        let f1 = -.dw *. eval_x(wl,wr,xl,xr) *. chiL_x(xl,xr) in
        ydot.{idx i 2} <- ydot.{idx i 2} +. quad(f1,f1,f1,xl,xr)
      end;
      (*    right test function *)
      if right then begin
        (*  u *)
        let f1 = -.du *. eval_x(ul,ur,xl,xr) *. chiR_x(xl,xr) in
        ydot.{idx (i+1) 0} <- ydot.{idx (i+1) 0} +. quad(f1,f1,f1,xl,xr);

        (*  v *)
        let f1 = -.dv *. eval_x(vl,vr,xl,xr) *. chiR_x(xl,xr) in
        ydot.{idx (i+1) 1} <- ydot.{idx (i+1) 1} +. quad(f1,f1,f1,xl,xr);

        (*  w *)
        let f1 = -.dw *. eval_x(wl,wr,xl,xr) *. chiR_x(xl,xr) in
        ydot.{idx (i+1) 2} <- ydot.{idx (i+1) 2} +. quad(f1,f1,f1,xl,xr);
      end
    done

  (* Routine to compute the ODE RHS function f(t,y), where system is of the form
          M y_t = f(t,y) := Ly + R(y)
     This routine only computes the f(t,y), leaving (M y_t) al1.0. *)
  let f ud t y ydot =
    (* clear out RHS (to be careful) *)
    RealArray.fill ydot 0.0;
    (* add reaction terms to RHS *)
    f_rx ud t y ydot;
    (* add diffusion terms to RHS *)
    f_diff ud t y ydot

  (* Interface routine to compute the Jacobian of the full RHS function, f(y) *)
  let jac ud =
    let r = ref None in
    fun { ARKStep.jac_y = (y : RealArray.t) } j ->
      let m, n = Matrix.Sparse.size j in
      let nnz, _ = Matrix.Sparse.dims j in

      (* ensure that Jac is the correct size *)
      if (m <> ud.n*3) || (n <> ud.n*3) then
        (printf "Jacobian calculation error: matrix is the wrong size!\n";
         raise RecoverableFailure);

      (* Fill in the Laplace matrix *)
      I.laplace_matrix ud j;

      (* Create empty reaction Jacobian matrix (if not done already) *)
      (match !r with
       | Some _ -> ()
       | None ->
          try r := Some (I.makemat m n nnz)
          with _ ->
            (printf "Jac: error in allocating R matrix!\n";
             raise RecoverableFailure));

      (* Add in the Jacobian of the reaction terms matrix *)
      (match !r with
       | None -> raise RecoverableFailure
       | Some r -> begin
           I.reaction_jac ud y r;
           (* Add R to J *)
           try Matrix.Sparse.scale_add 1.0 j r
           with _ ->
             (printf "Jac: error in adding sparse matrices!\n";
              raise RecoverableFailure)
         end)

  (* Main Program *)
  let main () =
    (* general problem parameters *)
    let t0 = 0.0 in         (* initial time *)
    let tf = 10.0 in        (* final time *)
    let nt = 100 in         (* total number of output times *)
    let nvar = 3 in         (* number of solution fields *)
    let reltol = 1.0e-6 in  (* tolerances *)
    let abstol = 1.0e-10 in

    (* if a command-line argument was supplied, set num_threads *)
    let num_threads =
      if Array.length Sys.argv <= 1 then 1 else int_of_string Sys.argv.(1)
    in

    (* allocate udata structure *)
    let n_mesh = 201 in
    let h = 10.0/.float (n_mesh-1) in
    let udata = {
      n = n_mesh;     (* spatial mesh size *)
      a = 0.6;
      b = 2.0;
      du = 0.025;
      dv = 0.025;
      dw = 0.025;
      ep = 1.0e-5;        (* stiffness parameter *)

      (* allocate and set up spatial mesh; this [arbitrarily] clusters
         more intervals near the end points of the interval *)
      x  = RealArray.init n_mesh
            (fun i -> let z = -5.0 +. h*.float i in
                      0.5/.atan(5.0)*.atan(z) +. 0.5);
    } in

    (* set total allocated vector length (N-1 intervals, Dirichlet end points) *)
    let neq = nvar * n_mesh in

    (* Initial problem output *)
    printf "\n1D FEM Brusselator PDE test problem:\n";
    printf "    N = %i,  NEQ = %i\n" n_mesh neq;
    printf "    num_threads = %i\n" num_threads;
    printf "    problem parameters:  a = %g,  b = %g,  ep = %g\n"
                                                       udata.a  udata.b  udata.ep;
    printf "    diffusion coefficients:  du = %g,  dv = %g,  dw = %g\n"
                                                       udata.du udata.dv udata.dw;
    printf "    reltol = %.1e,  abstol = %.1e\n\n" reltol abstol;

    (* Initialize data structures *)
    let data = RealArray.create neq in  (* Access data array for new NVector y *)
    let y = Nvector_serial.wrap data in (* Create serial vector for solution *)

    (* Set initial conditions into y *)
    let pi = 4.0*.atan(1.0) in
    for i=0 to n_mesh-1 do
      data.{idx i 0} <-      udata.a       +. 0.1*.sin(pi *. udata.x.{i}); (* u *)
      data.{idx i 1} <- udata.b /. udata.a +. 0.1*.sin(pi *. udata.x.{i}); (* v *)
      data.{idx i 2} <-      udata.b       +. 0.1*.sin(pi *. udata.x.{i})  (* w *)
    done;

    (* Create serial vector masks *)
    let umask = Nvector_serial.make neq 0.0 in
    let vmask = Nvector_serial.make neq 0.0 in
    let wmask = Nvector_serial.make neq 0.0 in

    (* Set mask array values for each solution component *)
    for i=0 to n_mesh-1 do
      (unwrap umask).{idx i 0} <- 1.0;
      (unwrap vmask).{idx i 1} <- 1.0;
      (unwrap wmask).{idx i 2} <- 1.0
    done;

    (* Call ARKodeInit to initialize the integrator memory and specify the
       hand-side side function in y'=f(t,y), the inital time t0, and
       the initial dependent variable vector y.  Note: since this
       problem is fully implicit, we set f_E to NULL and f_I to f. *)
    let nnz = 15 * neq in
    let m1 = I.newmat ~nnz neq in
    let m2 = I.newmat ~nnz neq in
    let arkode_mem = ARKStep.(
      init
        (implicit
          ~lsolver:Dls.(solver ~jac:(jac udata)
                               (superlumt ~nthreads:num_threads y m1))
          (f udata))
        (SStolerances (reltol, abstol))
        ~restol:(ResStolerance abstol)
        ~mass:Mass.Dls.(solver (I.mass_matrix udata) false
                               (superlumt ~nthreads:num_threads y m2))
        t0
        y
    ) in

    (* output mesh to disk *)
    let fid = open_out "bruss_FEM_mesh.txt" in
    for i=0 to n_mesh-1 do
      fprintf fid "  %.16e\n" udata.x.{i}
    done;
    close_out fid;

    (* Open output stream for results, access data arrays *)
    let ufid = open_out "bruss_FEM_u.txt" in
    let vfid = open_out "bruss_FEM_v.txt" in
    let wfid = open_out "bruss_FEM_w.txt" in

    (* output initial condition to disk *)
    for i=0 to n_mesh-1 do
      fprintf ufid " %.16e" data.{idx i 0};
      fprintf vfid " %.16e" data.{idx i 1};
      fprintf wfid " %.16e" data.{idx i 2}
    done;
    fprintf ufid "\n";
    fprintf vfid "\n";
    fprintf wfid "\n";

    (* Main time-stepping loop: calls ARKode to perform the integration, then
       prints results.  Stops when the final time has been reached *)
    let dTout = tf /. float nt in
    let tout = ref (t0+.dTout) in
    printf "        t      ||u||_rms   ||v||_rms   ||w||_rms\n";
    printf "   ----------------------------------------------\n";
    (try
       for iout=0 to nt-1 do
         (* call integrator *)
         let t, _ = ARKStep.solve_normal arkode_mem !tout y in

         (* access/print solution statistics *)
         let u = wl2norm y umask in
         let u = sqrt(u*.u/. float n_mesh) in
         let v = wl2norm y vmask in
         let v = sqrt(v*.v/. float n_mesh) in
         let w = wl2norm y wmask in
         let w = sqrt(w*.w/. float n_mesh) in
         printf "  %10.6f  %10.6f  %10.6f  %10.6f\n" t u v w;
         (* successful solve: update output time *)
         tout := min (!tout +. dTout) tf;

         (* output results to disk *)
         for i=0 to n_mesh-1 do
           fprintf ufid " %.16e" data.{idx i 0};
           fprintf vfid " %.16e" data.{idx i 1};
           fprintf wfid " %.16e" data.{idx i 2}
         done;
         fprintf ufid "\n";
         fprintf vfid "\n";
         fprintf wfid "\n"
       done
     with _ ->
       (* unsuccessful solve: break *)
       fprintf stderr "Solver failure, stopping integration\n");
    printf "   ----------------------------------------------\n";
    close_out ufid;
    close_out vfid;
    close_out wfid;

    (* Print some final statistics *)
    let open ARKStep in
    let nst      = get_num_steps arkode_mem in
    let nst_a    = get_num_step_attempts arkode_mem in
    let nfe, nfi = get_num_rhs_evals arkode_mem in
    let nsetups  = get_num_lin_solv_setups arkode_mem in
    let netf     = get_num_err_test_fails arkode_mem in
    let nni      = get_num_nonlin_solv_iters arkode_mem in
    let ncfn     = get_num_nonlin_solv_conv_fails arkode_mem in
    let nje      = Dls.get_num_jac_evals arkode_mem in

    printf "\nFinal Solver Statistics:\n";
    printf "   Internal solver steps = %d (attempted = %d)\n" nst nst_a;
    printf "   Total RHS evals:  Fe = %d,  Fi = %d\n" nfe nfi;
    (match Config.sundials_version with
     | 2, _, _ ->
        let nms = Mass.Dls.get_num_solves arkode_mem in
        printf "   Total mass matrix solves = %d\n" nms;
     | _, _, _ ->
        let nmset = Mass.Dls.get_num_setups arkode_mem in
        let nms = Mass.Dls.get_num_solves arkode_mem in
        let nmv = Mass.Dls.get_num_mult arkode_mem in
        printf "   Total mass matrix setups = %d\n" nmset;
        printf "   Total mass matrix solves = %d\n" nms;
        printf "   Total mass times evals = %d\n" nmv);
    printf "   Total linear solver setups = %d\n" nsetups;
    printf "   Total number of Jacobian evaluations = %d\n" nje;
    printf "   Total number of Newton iterations = %d\n" nni;
    printf "   Total number of nonlinear solver convergence failures = %d\n" ncfn;
    printf "   Total number of error test failures = %d\n" netf

end (* }}} *)

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

module CscProblem = Problem (Csc)
module CsrProblem = Problem (Csr)

(* Entry point *)
let _ =
  for i = 1 to reps do
    if sungte500 then CsrProblem.main ()
                 else CscProblem.main ();
    if gc_each_rep then Gc.compact ()
  done;
  if gc_at_end then Gc.compact ()

