(* * -----------------------------------------------------------------
 * $Revision:
 * $Date:
 * -----------------------------------------------------------------
 * Programmer(s): Cosmin Petra and Radu Serban @ LLNL
 * -----------------------------------------------------------------
 * OCaml port: Jun Inoue, Inria, Aug 2014.
 * -----------------------------------------------------------------
 * Example program for IDAS: Brusselator, parallel, GMRES, IDABBD
 * preconditioner, ASA
 *
 * This example program for IDAS uses IDASPGMR as the linear solver.
 * It is written for a parallel computer system and uses the
 * IDABBDPRE band-block-diagonal preconditioner module for the
 * IDASPGMR package.
 *
 * The mathematical problem solved in this example is a DAE system
 * that arises from a system of partial differential equations after
 * spatial discretization.
 *
 * The PDE system is a two-species time-dependent PDE known as
 * Brusselator PDE and models a chemically reacting system.
 *
 *
 *  du/dt = eps(u  + u) + u^2 v -(B+1)u + A
 *               xx   yy
 *                                          domain Omega = [0,L]X[0,L]
 *  dv/dt = eps(v  + v) - u^2 v + Bu
 *               xx   yy
 *
 *  B.C. : Neumann
 *  I.C  : u(x,y,t0) = u0(x,y) =  1  - 0.5*cos(pi*y/L)
 *         v(x,y,t0) = v0(x,y) = 3.5 - 2.5*cos(pi*x/L)
 *
 * The PDEs are discretized by central differencing on a MX by MY
 * mesh, and so the system size Neq is the product MX*MY*NUM_SPECIES.
 * The system is actually implemented on submeshes, processor by
 * processor, with an MXSUB by MYSUB mesh on each of NPEX * NPEY
 * processors.
 *
 *
 * The sensitivity of the output functional
 *                            1    /
 *                   g(t) = -----  | u(x,y,t) ,
 *                          |L^2|  /
 *                               Omega
 * with respect to initial conditions u0 and v0 is also computed.
 * Given the perturbations du0 and dv0 in the IC, the sensitivity of
 * of g at final time tf is
 *             1    /
 *  dg(tf) = -----  | ( lambda(0,x,y) du0(x,y) + mu(0,x,y) dv0(x,y) ),
 *           |L^2|  /
 *                Omega
 * where lambda and mu are the solutions of the adjoint PDEs:
 *
 *  dl/dt = - eps(l  + l) - (2uv - B - 1)l + (2uv - B)m
 *                 xx   yy
 *                                          domain Omega = [0,L]X[0,L]
 *  dm/dt = - eps(m  + m) - u^2 l + u^2 m
 *                 xx   yy
 * B.C. : Neumann
 * I.C. : l(x,y,tf) = 1
 *        m(x,y,tf) = 0
 *
 * The adjoint PDEs are discretized and solved in the same way as
 * the Brusselator PDEs.
 *)

open Sundials

let unvec = Nvector.unwrap
module Adjoint = Idas.Adjoint
open Nvector_parallel.DataOps

let fprintf = Printf.fprintf
let printf = Printf.printf

let slice = Bigarray.Array1.sub

let header_and_empty_array_size =
  Marshal.total_size (Marshal.to_bytes (RealArray.create 0) []) 0
let float_cell_size =
  Marshal.total_size (Marshal.to_bytes (RealArray.create 1) []) 0
  - header_and_empty_array_size

let bytes x = header_and_empty_array_size + x * float_cell_size

(* Problem Constants *)
let num_species = 2

let pi =          3.1415926535898 (* pi *)
let ctL =         1.0    (* Domain =[0,L]^2 *)
let ctA =         1.0
let ctB =         3.4
let ctEps =       2.0e-3

let mxsub =       21    (* Number of x mesh points per processor subgrid *)
let mysub =       21    (* Number of y mesh points per processor subgrid *)
let npex =        2     (* Number of subgrids in the x direction *)
let npey =        2     (* Number of subgrids in the y direction *)
let mx =          (mxsub*npex)      (* MX = number of x mesh points *)
let my =          (mysub*npey)      (* MY = number of y mesh points *)
let nsmxsub =     (num_species * mxsub)
let neq =         (num_species*mx*my) (* Number of equations in system *)

let rtol =        1.e-5  (*  rtol tolerance *)
let atol =        1.e-5  (*  atol tolerance *)

let tbegin =      0.0   (* Multiplier for tout values *)
let tend =        1.0    (* Increment for tout values *)

let steps =       50

let zero =        0.0
let half =        0.5
let one =         1.0
let two =         2.0

(* User-defined vector accessor macro IJ_Vptr. *)

(*
 * IJ_Vptr is defined in order to express the underlying 3-d structure of the
 * dependent variable vector from its underlying 1-d storage (an N_Vector).
 * IJ_Vptr(vv,i,j) returns a pointer to the location in vv corresponding to
 * species index is = 0, x-index ix = i, and y-index jy = j.
 *)

let index i j = i*num_species + j*nsmxsub
let ij_vptr (local,_,_) i j =
  let offset = index i j in
  slice local offset (RealArray.length local - offset)

(* Type: UserData.  Contains problem constants, preconditioner data, etc. *)
type user_data =
  {
    ns : int;
    thispe : int;
    npes : int;
    ixsub : int;
    jysub : int;
    npex : int;
    npey : int;
    mxsub : int;
    mysub : int;
    nsmxsub : int;
    nsmxsub2 : int;
    a : float;
    b : float;
    l : float;
    eps : RealArray.t;                  (* size = num_species *)
    dx : float;
    dy : float;
    cox : RealArray.t;                  (* size = num_species *)
    coy : RealArray.t;                  (* size = num_species *)
    gridext : RealArray.t;              (* size = (mxsub+2)*(mysub+2)*num_species *)
    rhs : RealArray.t;                  (* size = num_species *)
    comm : Mpi.communicator;
    rates : RealArray.t;                (* size = 2 *)
    n_local : int;
  }

(*
 *--------------------------------------------------------------------
 * FUNCTIONS CALLED BY IDA & SUPPORTING FUNCTIONS
 *--------------------------------------------------------------------
 *)

(*
 * BRecvPost: Start receiving boundary data from neighboring PEs.
 * (1) buffer should be able to hold 2*num_species*mysub realtype entries,
 *     should be passed to both the BRecvPost and BRecvWait functions, and
 *     should not be manipulated between the two calls.
 * (2) request should have 4 entries, and is also passed in both calls.
 *)

let brecvpost comm my_pe ixsub jysub dsizex dsizey _ =
  (* If jysub > 0, receive data for bottom x-line of cext. *)
  let r0 = if jysub <> 0
           then Mpi.ireceive (bytes dsizex) (my_pe-npex) 0 comm
           else Mpi.null_request
  in

  (* If jysub < npey-1, receive data for top x-line of cext. *)
  let r1 = if jysub <> npey-1
           then Mpi.ireceive (bytes dsizex) (my_pe+npex) 0 comm
           else Mpi.null_request
  in

  (* If ixsub > 0, receive data for left y-line of cext (via bufleft). *)
  let r2 = if ixsub <> 0
           then Mpi.ireceive (bytes dsizey) (my_pe-1) 0 comm
           else Mpi.null_request
  in

  (* If ixsub < npex-1, receive data for right y-line of cext (via bufright). *)
  let r3 = if ixsub <> npex-1
           then Mpi.ireceive (bytes dsizey) (my_pe+1) 0 comm
           else Mpi.null_request
  in
  [|r0;r1;r2;r3|]


(*
 * BRecvWait: Finish receiving boundary data from neighboring PEs.
 * (1) buffer should be able to hold 2*num_species*mysub realtype entries,
 *     should be passed to both the BRecvPost and BRecvWait functions, and
 *     should not be manipulated between the two calls.
 * (2) request should have 4 entries, and is also passed in both calls.
 *)


let brecvwait request ixsub jysub dsizex cext =
  let dsizex2 = dsizex + 2*num_species in

  (* If jysub > 0, receive data for bottom x-line of cext. *)
  if jysub <> 0 then begin
    let buf = (Mpi.wait_receive request.(0) : RealArray.t) in
    RealArray.blitn ~src:buf ~dst:cext ~dpos:num_species dsizex
  end;

  (* If jysub < npey-1, receive data for top x-line of cext. *)
  if jysub <> npey-1 then begin
    let buf = (Mpi.wait_receive request.(1) : RealArray.t) in
    let offsetce = num_species*(1 + (mysub+1)*(mxsub+2)) in
    RealArray.blitn ~src:buf ~dst:cext ~dpos:offsetce dsizex
  end;

  (* If ixsub > 0, receive data for left y-line of cext (via bufleft). *)
  if ixsub <> 0 then begin
    let bufleft = (Mpi.wait_receive request.(2) : RealArray.t) in

    (* Copy the buffer to cext *)
    for ly = 0 to mysub-1 do
      let offsetbuf = ly*num_species in
      let offsetce = (ly+1)*dsizex2 in
      for i = 0 to num_species-1 do
        cext.{offsetce+i} <- bufleft.{offsetbuf+i}
      done
    done
  end;

  (* If ixsub < npex-1, receive data for right y-line of cext (via bufright). *)
  if ixsub <> npex-1 then begin
    let bufright = (Mpi.wait_receive request.(3) : RealArray.t) in

    (* Copy the buffer to cext *)
    for ly = 0 to mysub-1 do
      let offsetbuf = ly*num_species in
      let offsetce = (ly+2)*dsizex2 - num_species in
      for i = 0 to num_species-1 do
        cext.{offsetce+i} <- bufright.{offsetbuf+i}
      done
    done
  end


(*
 * BSend: Send boundary data to neighboring PEs.
 * This routine sends components of uv from internal subgrid boundaries
 * to the appropriate neighbor PEs.
 *)

let bsend comm my_pe ixsub jysub dsizex dsizey cdata =
  let bufleft = RealArray.create (num_species * mysub)
  and bufright = RealArray.create (num_species * mysub)
  in
  (* If jysub > 0, send data from bottom x-line of uv. *)

  if jysub <> 0 then
    Mpi.send (slice cdata 0 dsizex) (my_pe-npex) 0 comm
  ;

  (* If jysub < npey-1, send data from top x-line of uv. *)

  if jysub <> npey-1 then begin
    let offsetc = (mysub-1)*dsizex in
    Mpi.send (slice cdata offsetc dsizex) (my_pe+npex) 0 comm
  end;

  (* If ixsub > 0, send data from left y-line of uv (via bufleft). *)

  if ixsub <> 0 then begin
    for ly = 0 to mysub-1 do
      let offsetbuf = ly*num_species in
      let offsetc = ly*dsizex in
      for i = 0 to num_species-1 do
        bufleft.{offsetbuf+i} <- cdata.{offsetc+i}
      done
    done;
    Mpi.send (slice bufleft 0 dsizey) (my_pe-1) 0 comm
  end;

  (* If ixsub < npex-1, send data from right y-line of uv (via bufright). *)

  if ixsub <> npex-1 then begin
    for ly = 0 to mysub-1 do
      let offsetbuf = ly*num_species in
      let offsetc = offsetbuf*mxsub + (mxsub-1)*num_species in
      for i = 0 to num_species-1 do
        bufright.{offsetbuf+i} <- cdata.{offsetc+i}
      done
    done;
    Mpi.send (slice bufright 0 dsizey) (my_pe+1) 0 comm
  end

(*
 * ReactRates: Evaluate reaction rates at a given spatial point.
 * At a given (x,y), evaluate the array of ns reaction terms R.
 *)
let react_rates data _ _ ((uvval : RealArray.t), uvval_off)
                         (rates : RealArray.t) =
  let a = data.a and b = data.b in

  rates.{0} <- uvval.{uvval_off}*.uvval.{uvval_off}*.uvval.{uvval_off + 1};
  rates.{1} <- -. rates.{0};

  rates.{0} <- rates.{0} +. (a-.(b+.1.0)*.uvval.{uvval_off});
  rates.{1} <- rates.{1} +. b*.uvval.{uvval_off}


(*
 * reslocal: Compute res = F(t,uv,uvp).
 * This routine assumes that all inter-processor communication of data
 * needed to calculate F has already been done.  Components at interior
 * subgrid boundaries are assumed to be in the work array cext.
 * The local portion of the uv vector is first copied into cext.
 * The exterior Neumann boundary conditions are explicitly handled here
 * by copying data from the first interior mesh line to the ghost cell
 * locations in cext.  Then the reaction and diffusion terms are
 * evaluated in terms of the cext array, and the residuals are formed.
 * The reaction terms are saved separately in the vector data.rates
 * for use by the preconditioner setup routine.
 *)
let reslocal data _ ((uv : RealArray.t), _, _)
                    ((uvp : RealArray.t), _, _)
                    ((rr : RealArray.t), _, _) =
  let mxsub =      data.mxsub in
  let mysub =      data.mysub in
  let npex =       data.npex in
  let npey =       data.npey in
  let ixsub =      data.ixsub in
  let jysub =      data.jysub in
  let nsmxsub =    data.nsmxsub in
  let nsmxsub2 =   data.nsmxsub2 in
  let dx =         data.dx in
  let dy =         data.dy in
  let gridext =    data.gridext in
  let eps =        data.eps in
  (* Get data pointers, subgrid data, array sizes, work array cext. *)
  let rates = RealArray.create 2 in

  let dx2 = dx *. dx in
  let dy2 = dy *. dy in

  (* Copy local segment of uv vector into the working extended array gridext. *)
  let locc = ref 0 in
  let locce = ref (nsmxsub2 + num_species) in
  for _ = 0 to mysub-1 do
    for i = 0 to nsmxsub-1 do
      gridext.{!locce+i} <- uv.{!locc+i}
    done;
    locc := !locc + nsmxsub;
    locce := !locce + nsmxsub2;
  done;

  (* To facilitate homogeneous Neumann boundary conditions, when this is
     a boundary PE, copy data from the first interior mesh line of uv to gridext. *)

  (* If jysub = 0, copy x-line 2 of uv to gridext. *)
  if jysub = 0 then
    for i = 0 to nsmxsub-1 do
      gridext.{num_species+i} <- uv.{nsmxsub+i}
    done
  ;

  (* If jysub = npey-1, copy x-line mysub-1 of uv to gridext. *)
  if jysub = npey-1 then begin
    let locc = (mysub-2)*nsmxsub in
    let locce = (mysub+1)*nsmxsub2 + num_species in
    for i = 0 to nsmxsub-1 do
      gridext.{locce+i} <- uv.{locc+i}
    done
  end;


  (* If ixsub = 0, copy y-line 2 of uv to gridext. *)
  if ixsub = 0 then begin
    for jy = 0 to mysub-1 do
      let locc = jy*nsmxsub + num_species in
      let locce = (jy+1)*nsmxsub2 in
      for i = 0 to num_species-1 do
        gridext.{locce+i} <- uv.{locc+i}
      done
    done
  end;


  (* If ixsub = npex-1, copy y-line mxsub-1 of uv to gridext. *)
  if ixsub = npex-1 then begin
    for jy = 0 to mysub-1 do
      let locc = (jy+1)*nsmxsub - 2*num_species in
      let locce = (jy+2)*nsmxsub2 - num_species in
      for i = 0 to num_species-1 do
        gridext.{locce+i} <- uv.{locc+i}
      done
    done
  end;

  (* Loop over all grid points, setting local array rates to right-hand sides.
     Then set rr values appropriately (ODE in the interior and DAE on the boundary)*)
  let ixend = if ixsub=npex-1 then 1 else 0 in
  let ixstart = if ixsub=0 then 1 else 0 in
  let jystart = if jysub=0 then 1 else 0 in
  let jyend = if jysub=npey-1 then 1 else 0 in

  for jy = jystart to mysub-jyend-1 do
    let ylocce = (jy+1)*nsmxsub2 in
    let yy = float_of_int(jy+jysub*mysub)*.dy in

    for ix = ixstart to mxsub-ixend-1 do
      let locce = ylocce + (ix+1)*num_species in
      let xx = float_of_int(ix + ixsub*mxsub)*.dx in

      react_rates data xx yy (gridext, locce) rates;

      let off = index ix jy in
      for is = 0 to num_species-1 do
        let dcyli = gridext.{locce+is}          -. gridext.{locce+is-nsmxsub2} in
        let dcyui = gridext.{locce+is+nsmxsub2} -. gridext.{locce+is} in

        let dcxli = gridext.{locce+is}             -. gridext.{locce+is-num_species} in
        let dcxui = gridext.{locce+is+num_species} -. gridext.{locce+is} in

        rr.{off + is} <- uvp.{off + is}
                      -. eps.{is}*.( (dcxui-.dcxli)/.dx2 +. (dcyui-.dcyli)/.dy2 )
                      -. rates.{is};
      done
    done
  done;

  if jysub=0 then begin
    for ix = 0 to mxsub-1 do
      let locce = nsmxsub2 + num_species * (ix+1) in
      let off = index ix 0 in

      for is = 0 to num_species-1 do
        rr.{off + is} <- gridext.{locce+is+nsmxsub2} -. gridext.{locce+is}
      done
    done
  end;

  if ixsub=npex-1 then begin
    for jy = 0 to mysub-1 do
      let locce = (jy+1)*nsmxsub2 + nsmxsub2-num_species in
      let off = index (mxsub-1) jy in

      for is = 0 to num_species-1 do
        rr.{off + is} <- gridext.{locce+is-num_species} -. gridext.{locce+is}
      done
    done
  end;

  if ixsub=0 then begin
    for jy = 0 to mysub-1 do
      let locce = (jy+1)*nsmxsub2 + num_species in
      let off = index 0 jy in

      for is = 0 to num_species-1 do
        rr.{off + is} <- gridext.{locce+is-num_species} -. gridext.{locce+is}
      done
    done
  end;

  if jysub=npey-1 then begin
    for ix = 0 to mxsub-1 do
      let locce = nsmxsub2*mysub + (ix+1)*num_species in
      let off = index ix (mysub-1) in

      for is = 0 to num_species-1 do
        rr.{off + is} <- gridext.{locce+is-nsmxsub2} -. gridext.{locce+is}
      done
    done
  end

(*
 * rescomm: Communication routine in support of resweb.
 * This routine performs all inter-processor communication of components
 * of the uv vector needed to calculate F, namely the components at all
 * interior subgrid boundaries (ghost cell data).  It loads this data
 * into a work array cext (the local portion of c, extended).
 * The message-passing uses blocking sends, non-blocking receives,
 * and receive-waiting, in routines BRecvPost, BSend, BRecvWait.
 *)

let rescomm data _ uv _ =
  let cdata,_,_ = uv in

  (* Get comm, thispe, subgrid indices, data sizes, extended array cext. *)
  let comm = data.comm in
  let thispe = data.thispe in

  let ixsub = data.ixsub in
  let jysub = data.jysub in
  let gridext = data.gridext in
  let nsmxsub = data.nsmxsub in
  let nsmysub = (data.ns)*(data.mysub) in

  (* Start receiving boundary data from neighboring PEs. *)
  let request = brecvpost comm thispe ixsub jysub nsmxsub nsmysub gridext
  in

  (* Send data from boundary of local grid to neighboring PEs. *)
  bsend comm thispe ixsub jysub nsmxsub nsmysub cdata;

  (* Finish receiving boundary data from neighboring PEs. *)
  brecvwait request ixsub jysub nsmxsub gridext

(*
 * res: System residual function
 *
 * To compute the residual function F, this routine calls:
 * rescomm, for needed communication, and then
 * reslocal, for computation of the residuals on this processor.
 *)

let res data tt uv uvp rr =
  (* Call rescomm to do inter-processor communication. *)
  rescomm data tt uv uvp;

  (* Call reslocal to calculate the local portion of residual vector. *)
  reslocal data tt uv uvp rr

let resBlocal : user_data -> Idas_bbd.local_fn =
  fun data { Adjoint.y = (uv, _, _);
             Adjoint.yb = (uvB, _, _);
             Adjoint.yb' = (uvpB, _, _); _ } (rrB, _, _) ->
  let b = data.b in
  let mxsub =      data.mxsub in
  let mysub =      data.mysub in
  let npex =       data.npex in
  let npey =       data.npey in
  let ixsub =      data.ixsub in
  let jysub =      data.jysub in
  let nsmxsub =    data.nsmxsub in
  let nsmxsub2 =   data.nsmxsub2 in
  let dx =         data.dx in
  let dy =         data.dy in
  let gridext =    data.gridext in
  let eps =        data.eps in


  (* Get data pointers, subgrid data, array sizes, work array cext. *)
  let dx2 = dx *. dx in
  let dy2 = dy *. dy in

  (* Copy local segment of uv vector into the working extended array gridext. *)
  let locc = ref 0 in
  let locce = ref (nsmxsub2 + num_species) in
  for _ = 0 to mysub-1 do
    for i = 0 to nsmxsub-1 do
      gridext.{!locce+i} <- uvB.{!locc+i}
    done;
    locc := !locc + nsmxsub;
    locce := !locce + nsmxsub2
  done;

  (* If jysub = 0, copy x-line 2 of uv to gridext. *)
  if jysub = 0 then
    for i = 0 to nsmxsub-1 do
      gridext.{num_species+i} <- uvB.{nsmxsub+i}
    done
  ;


  (* If jysub = npey-1, copy x-line mysub-1 of uv to gridext. *)
  if jysub = npey-1 then begin
    let locc = (mysub-2)*nsmxsub in
    let locce = (mysub+1)*nsmxsub2 + num_species in
    for i = 0 to nsmxsub-1 do
      gridext.{locce+i} <- uvB.{locc+i}
    done
  end;


  (* If ixsub = 0, copy y-line 2 of uv to gridext. *)
  if ixsub = 0 then begin
    for jy = 0 to mysub-1 do
      let locc = jy*nsmxsub + num_species in
      let locce = (jy+1)*nsmxsub2 in
      for i = 0 to num_species-1 do
        gridext.{locce+i} <- uvB.{locc+i}
      done
    done
  end;

  (* If ixsub = npex-1, copy y-line mxsub-1 of uv to gridext. *)
  if ixsub = npex-1 then begin
    for jy = 0 to mysub-1 do
      let locc = (jy+1)*nsmxsub - 2*num_species in
      let locce = (jy+2)*nsmxsub2 - num_species in
      for i = 0 to num_species-1 do
        gridext.{locce+i} <- uvB.{locc+i}
      done
    done
  end;

  (* Loop over all grid points, setting local array rates to right-hand sides.
     Then set rr values appropriately (ODE in the interior and DAE on the boundary)*)
  let ixend = if ixsub=npex-1 then 1 else 0 in
  let ixstart = if ixsub=0 then 1 else 0 in
  let jystart = if jysub=0 then 1 else 0 in
  let jyend = if jysub=npey-1 then 1 else 0 in

  for jy = jystart to mysub-jyend-1 do
    let ylocce = (jy+1)*nsmxsub2 in

    for ix = ixstart to mxsub-ixend-1 do
      let locce = ylocce + (ix+1)*num_species in

      let off = index ix jy in
      for is = 0 to num_species-1 do
        let dcyli = gridext.{locce+is}          -. gridext.{locce+is-nsmxsub2} in
        let dcyui = gridext.{locce+is+nsmxsub2} -. gridext.{locce+is} in

        let dcxli = gridext.{locce+is}             -. gridext.{locce+is-num_species} in
        let dcxui = gridext.{locce+is+num_species} -. gridext.{locce+is} in

        rrB.{off + is} <- uvpB.{off + is} +. eps.{is}*.( (dcxui-.dcxli)/.dx2 +. (dcyui-.dcyli)/.dy2 );
      done;

      (* now add rates *)
      rrB.{off} <- rrB.{off}
                   +. (uvB.{off}-.uvB.{off + 1})*.(2.0*.uv.{off}*.uv.{off + 1} -. b)
                   -. uvB.{off};
      rrB.{off + 1} <- rrB.{off + 1} +. uv.{off + 0}*.uv.{off}*.(uvB.{off}-.uvB.{off + 1});
    done
  done;

  if jysub=0 then begin
    for ix = 0 to mxsub-1 do
      let locce = nsmxsub2 + num_species * (ix+1) in
      let off = index ix 0 in

      for is = 0 to num_species-1 do
        rrB.{off + is} <- gridext.{locce+is+nsmxsub2} -. gridext.{locce+is}
      done
    done
  end;

  if ixsub=npex-1 then begin
    for jy = 0 to mysub-1 do
      let locce = (jy+1)*nsmxsub2 + nsmxsub2-num_species in
      let off = index (mxsub-1) jy in

      for is = 0 to num_species-1 do
        rrB.{off + is} <- gridext.{locce+is-num_species} -. gridext.{locce+is}
      done
    done
  end;

  if ixsub=0 then begin
    for jy = 0 to mysub-1 do
      let locce = (jy+1)*nsmxsub2 + num_species in
      let off = index 0 jy in

      for is = 0 to num_species-1 do
        rrB.{off + is} <- gridext.{locce+is-num_species} -. gridext.{locce+is}
      done
    done
  end;

  if jysub=npey-1 then begin
    for ix = 0 to mxsub-1 do
      let locce = nsmxsub2*mysub + (ix+1)*num_species in
      let off = index ix (mysub-1) in

      for is = 0 to num_species-1 do
        rrB.{off + is} <- gridext.{locce+is-nsmxsub2} -. gridext.{locce+is}
      done
    done
  end

let resB data { Adjoint.t = tt; Adjoint.y = yy; Adjoint.y' = yp;
                Adjoint.yb = yyB; Adjoint.yb' = ypB } rrB =

  (* Call rescomm to do inter-processor communication. *)
  rescomm data tt yyB ypB;

  (* Call reslocal to calculate the local portion of residual vector. *)
  let args = { Adjoint.t = tt; Adjoint.y = yy; Adjoint.y' = yp;
               Adjoint.yb = yyB; Adjoint.yb' = ypB; }
  in
  resBlocal data args rrB

(*
 *--------------------------------------------------------------------
 * PRIVATE FUNCTIONS
 *--------------------------------------------------------------------
 *)

(*
 * InitUserData: Load problem constants in data (of type UserData).
 *)
let init_user_data thispe npes comm =
  let jysub = thispe / npex in
  let ixsub = thispe - (jysub)*npex in
  let ns = num_species in
  let dx = ctL/.float_of_int(mx-1) in
  let dy = ctL/.float_of_int(my-1) in
  let thispe = thispe in
  let npes = npes in
  let nsmxsub = mxsub * num_species in
  let nsmxsub2 = (mxsub+2)*num_species in
  let n_local = mxsub*mysub*num_species in
  let a = ctA in
  let b = ctB in
  let l = ctL in
  let eps = RealArray.of_array [|ctEps; ctEps|] in
  {
    ns = ns;
    thispe = thispe;
    npes = npes;
    ixsub = ixsub;
    jysub = jysub;
    npex = npex;
    npey = npey;
    mxsub = mxsub;
    mysub = mysub;
    nsmxsub = nsmxsub;
    nsmxsub2 = nsmxsub2;
    a = a;
    b = b;
    l = l;
    eps = eps;
    dx = dx;
    dy = dy;
    cox = RealArray.create num_species;
    coy = RealArray.create num_species;
    gridext = RealArray.create ((mxsub+2)*(mysub+2)*num_species);
    rhs = RealArray.create num_species;
    comm = comm;
    rates = RealArray.create 2;
    n_local = n_local;
  }


(*
 * SetInitialProfiles: Set initial conditions in uv, uvp, and id.
 *)

let set_initial_profiles data uv uvp id resid =
  let ixsub = data.ixsub in
  let jysub = data.jysub in
  let mxsub = data.mxsub in
  let mysub = data.mysub in
  let npex = data.npex in
  let npey = data.npey in
  let dx = data.dx in
  let dy = data.dy in
  let l = data.l in

  const 0. uv;

  (* Loop over grid, load uv values and id values. *)
  for jy = 0 to mysub-1 do
    let y = float_of_int(jy + jysub*mysub) *. dy in
    for ix = 0 to mxsub-1 do

      let x = float_of_int(ix + ixsub*mxsub) *. dx in
      let uvxy = ij_vptr uv ix jy in

      uvxy.{0} <- 1.0 -. half*.cos(pi*.y/.l);
      uvxy.{1} <- 3.5 -. 2.5*.cos(pi*.x/.l);
    done
  done;

  const one id;

  if jysub = 0 then begin
    for ix = 0 to mxsub-1 do
      let idxy = ij_vptr id ix 0 in
      idxy.{0} <- zero;
      idxy.{1} <- zero;

      let uvxy = ij_vptr uv ix 0 in
      let uvxy1 = ij_vptr uv ix 1 in
      uvxy.{0} <- uvxy1.{0};
      uvxy.{1} <- uvxy1.{1};
    done
  end;

  if ixsub = npex-1 then begin
    for jy = 0 to mysub-1 do
      let idxy = ij_vptr id (mxsub-1) jy in
      idxy.{0} <- zero;
      idxy.{1} <- zero;

      let uvxy = ij_vptr uv (mxsub-1) jy in
      let uvxy1 = ij_vptr uv (mxsub-2) jy in
      uvxy.{0} <- uvxy1.{0};
      uvxy.{1} <- uvxy1.{1};

    done
  end;

  if ixsub = 0 then begin
    for jy = 0 to mysub-1 do
      let idxy = ij_vptr id 0 jy in
      idxy.{0} <- zero;
      idxy.{1} <- zero;

      let uvxy = ij_vptr uv 0 jy in
      let uvxy1 = ij_vptr uv 1 jy in
      uvxy.{0} <- uvxy1.{0};
      uvxy.{1} <- uvxy1.{1}
    done
  end;

  if jysub = npey-1 then begin
    for ix = 0 to mxsub-1 do
      let idxy = ij_vptr id ix jysub in
      idxy.{0} <- zero;
      idxy.{1} <- zero;

      let uvxy = ij_vptr uv ix (mysub-1) in
      let uvxy1 = ij_vptr uv ix (mysub-2) in
      uvxy.{0} <- uvxy1.{0};
      uvxy.{1} <- uvxy1.{1}
    done
  end;

  (* Derivative found by calling the residual function with uvp = 0. *)
  const zero uvp;
  res data zero uv uvp resid;
  scale (-.one) resid uvp

(*
 * SetInitialProfilesB: Set initial conditions in uvB, uvpB
 *)

let set_initial_profiles_b uv _ uvB uvpB _ data =
  let ixsub = data.ixsub in
  let jysub = data.jysub in
  let mxsub = data.mxsub in
  let mysub = data.mxsub in
  let npex = data.npex in
  let npey = data.npey in
  let b = data.b in

  (* Loop over grid, load (lambda, mu) values. *)
  for jy = 0 to mysub-1 do
    for ix = 0 to mxsub-1 do
      let uvBxy = ij_vptr uvB ix jy in
      let uvpBxy = ij_vptr uvpB ix jy in

      let uvxy = ij_vptr uv ix jy in

      uvBxy.{0} <- one;
      uvBxy.{1} <- zero;

      uvpBxy.{0} <- -.two*.uvxy.{0}*.uvxy.{1}+.(b+.1.0);
      uvpBxy.{1} <- -.uvxy.{0}*.uvxy.{0};
    done
  done;

  if jysub = 0 then begin
    for ix = 0 to mxsub-1 do

      let uvpBxy = ij_vptr uvpB ix 0 in

      uvpBxy.{0} <- zero;
      uvpBxy.{1} <- zero;
    done
  end;

  if ixsub = npex-1 then begin
    for jy = 0 to mysub-1 do

      let uvpBxy = ij_vptr uvpB (mxsub-1) jy in

      uvpBxy.{0} <- zero;
      uvpBxy.{1} <- zero;
    done
  end;

  if ixsub = 0 then begin
    for jy = 0 to mysub-1 do

      let uvpBxy = ij_vptr uvpB 0 jy in

      uvpBxy.{0} <- zero;
      uvpBxy.{1} <- zero;
    done
  end;

  if jysub = npey-1 then begin
    for ix = 0 to mxsub-1 do

      let uvpBxy = ij_vptr uvpB ix (mysub-1) in

      uvpBxy.{0} <- zero;
      uvpBxy.{1} <- zero;
    done
  end


(*
 * Print first lines of output (problem description)
 * and table headerr
 *)

let idaspgmr =
  match Config.sundials_version with
  | 2,_,_ -> "IDASPGMR"
  | 3,_,_ -> "SUNSPGMR"
  | _,_,_ -> "SUNLinSol_SPGMR"

let print_header system_size maxl mudq mldq mukeep mlkeep rtol atol =
  printf "\n BRUSSELATOR: chemically reacting system\n\n";
  printf "Number of species ns: %d" num_species;
  printf "     Mesh dimensions: %d x %d\n" mx my;
  printf "Total system size: %d\n" system_size;
  printf "Subgrid dimensions: %d x %d" mxsub mysub;
  printf "     Processor array: %d x %d\n" npex npey;
  printf "Tolerance parameters:  rtol = %g   atol = %g\n" rtol atol;
  printf "Linear solver: %s     Max. Krylov dimension maxl: %d\n" idaspgmr maxl;
  printf "Preconditioner: band-block-diagonal (IDABBDPRE), with parameters\n";
  printf "     mudq = %d,  mldq = %d,  mukeep = %d,  mlkeep = %d\n"
         mudq mldq mukeep mlkeep;

  printf "-----------------------------------------------------------\n";
  printf "  t        bottom-left  top-right";
  printf "    | nst  k      h\n";
  printf "-----------------------------------------------------------\n\n"



(*
 * PrintOutput: Print output values at output time t = tt.
 * Selected run statistics are printed.  Then values of c1 and c2
 * are printed for the bottom left and top right grid points only.
 *)
let print_output mem uv tt data comm =
  let thispe = data.thispe in
  let npelast = data.npes - 1 in
  let cdata = Nvector_parallel.local_array uv in
  let clast = RealArray.create 2 in

  (* Send conc. at top right mesh point from PE npes-1 to PE 0. *)
  if thispe = npelast then begin
    let ilast = num_species*mxsub*mysub - 2 in
    if npelast <> 0
    then Mpi.send (slice cdata ilast 2) 0 0 comm
    else (clast.{0} <- cdata.{ilast}; clast.{1} <- cdata.{ilast+1})
  end;

  (* On PE 0, receive conc. at top right from PE npes - 1.
     Then print performance data and sampled solution values. *)
  if thispe = 0 then begin

    if npelast <> 0 then begin
      let buf = (Mpi.receive npelast 0 comm : RealArray.t) in
      RealArray.blitn ~src:buf ~dst:clast 2
    end;

    let kused = Ida.get_last_order mem in
    let nst   = Ida.get_num_steps mem in
    let hused = Ida.get_last_step mem in

    printf "%8.2e %12.4e %12.4e   | %3d  %1d %12.4e\n"
         tt cdata.{0} clast.{0} nst kused hused;
    for i = 1 to num_species-1 do
      printf "         %12.4e %12.4e   |\n" cdata.{i} clast.{i}
    done;
    printf "\n"
  end

let print_sol _ uv _ data _ =
  let thispe = data.thispe in
  let szFilename = Printf.sprintf "ysol%da.txt" thispe in

  (* NB: the original C code opens with "w+" instead of "w", but seems
     to only write to the file. *)
  let fout =
    try open_out szFilename
    with e ->
      printf "PE[% 2d] is unable to write solution to disk!\n" thispe;
      raise e
  in

  let npex = data.npex in

  let mxsub = data.mxsub in
  let mysub = data.mysub in

  let ixsub = data.ixsub in
  let jysub = data.jysub in

  let nsmxsub = data.nsmxsub in

  for jy = 0 to mysub-1 do

    let j = jysub*mysub+jy in

    for ix = 0 to mxsub-1 do

      let i = ix + mxsub*ixsub in
      if mxsub<5 && mysub<5 then
        printf "PE 2D[% 2d][% 2d] -- 1D[% 2d]  subgrid[%d][%d]  uv[%d][%d] uv[[%d]]\n"
               ixsub jysub thispe ix jy i j
               ((i)*num_species + (j)*nsmxsub*npex);
      let uvxy = ij_vptr uv ix jy in
      fprintf fout "%g\n%g\n" uvxy.{0} uvxy.{1};
    done
  done;
  close_out fout


let print_adj_sol uvB _ data =
  let thispe = data.thispe in
  let szFilename = Printf.sprintf "ysol%dadj.txt" thispe in

  (* NB: the original C code opens with "w+" instead of "w", but seems
     to only write to the file. *)
  let fout =
    try open_out szFilename
    with e ->
      printf "PE[% 2d] is unable to write adj solution to disk!\n" thispe;
      raise e
  in

  let mxsub = data.mxsub in
  let mysub = data.mysub in

  for jy = 0 to mysub-1 do
    for ix = 0 to mxsub-1 do
      let uvxy = ij_vptr uvB ix jy in
      fprintf fout "%g\n%g\n" uvxy.{0} uvxy.{1};
    done
  done;
  close_out fout

(*
 * PrintFinalStats: Print final run data contained in iopt.
 *)

let print_final_stats mem =
  let open Ida in
  let nst  = get_num_steps mem in
  let nre  = get_num_res_evals mem in
  let netf = get_num_err_test_fails mem in
  let ncfn = get_num_nonlin_solv_conv_fails mem in
  let nni  = get_num_nonlin_solv_iters mem in

  let ncfl  = Spils.get_num_lin_conv_fails mem in
  let nli   = Spils.get_num_lin_iters mem in
  let npe   = Spils.get_num_prec_evals mem in
  let nps   = Spils.get_num_prec_solves mem in
  let nreLS = Spils.get_num_lin_res_evals mem in

  let nge = Ida_bbd.get_num_gfn_evals mem in

  printf "-----------------------------------------------------------\n";
  printf "\nFinal statistics: \n\n";

  printf "Number of steps                    = %d\n" nst;
  printf "Number of residual evaluations     = %d\n" (nre+nreLS);
  printf "Number of nonlinear iterations     = %d\n" nni;
  printf "Number of error test failures      = %d\n" netf;
  printf "Number of nonlinear conv. failures = %d\n\n" ncfn;

  printf "Number of linear iterations        = %d\n" nli;
  printf "Number of linear conv. failures    = %d\n\n" ncfl;

  printf "Number of preconditioner setups    = %d\n" npe;
  printf "Number of preconditioner solves    = %d\n" nps;
  printf "Number of local residual evals.    = %d\n" nge

let print_final_stats_b mem =
  let open Adjoint in
  let nst  = get_num_steps mem in
  let nre  = get_num_res_evals mem in
  let netf = get_num_err_test_fails mem in
  let ncfn = get_num_nonlin_solv_conv_fails mem in
  let nni  = get_num_nonlin_solv_iters mem in

  let ncfl  = Spils.get_num_lin_conv_fails mem in
  let nli   = Spils.get_num_lin_iters mem in
  let npe   = Spils.get_num_prec_evals mem in
  let nps   = Spils.get_num_prec_solves mem in
  let nreLS = Spils.get_num_lin_res_evals mem in

  let nge = Idas_bbd.get_num_gfn_evals mem in

  printf "-----------------------------------------------------------\n";
  printf "\nFinal statistics: \n\n";

  printf "Number of steps                    = %d\n" nst;
  printf "Number of residual evaluations     = %d\n" (nre+nreLS);
  printf "Number of nonlinear iterations     = %d\n" nni;
  printf "Number of error test failures      = %d\n" netf;
  printf "Number of nonlinear conv. failures = %d\n\n" ncfn;

  printf "Number of linear iterations        = %d\n" nli;
  printf "Number of linear conv. failures    = %d\n\n" ncfl;

  printf "Number of preconditioner setups    = %d\n" npe;
  printf "Number of preconditioner solves    = %d\n" nps;
  printf "Number of local residual evals.    = %d\n" nge

(*
 *--------------------------------------------------------------------
 * MAIN PROGRAM
 *--------------------------------------------------------------------
 *)

let main () =

  (* Set communicator, and get processor number and total number of PE's. *)
  let comm = Mpi.comm_world in
  let thispe = Mpi.comm_rank comm in
  let npes = Mpi.comm_size comm in

  if npes <> npex*npey then begin
    if thispe = 0 then
      fprintf stderr
        "\nMPI_ERROR(0): npes = %d not equal to NPEX*NPEY = %d\n"
        npes (npex*npey)
    ;
    exit 1
  end;

  (* Set local length (local_N) and global length (system_size). *)
  let local_N = mxsub*mysub*num_species in
  let system_size = neq in

  (* Set up user data block data. *)
  let data = init_user_data thispe npes comm in

  (* Create needed vectors, and load initial values.
     The vector resid is used temporarily only.        *)

  let open Nvector_parallel in
  let uv    = make local_N system_size comm 0. in
  let uvp   = make local_N system_size comm 0. in
  let resid = make local_N system_size comm 0. in
  let id    = make local_N system_size comm 0. in

  set_initial_profiles data (unvec uv) (unvec uvp)
    (unvec id) (unvec resid);

  res data zero (unvec uv) (unvec uvp) (unvec resid);

  (* Set remaining inputs to IDAS. *)
  let t0 = zero in

  (* Call IDACreate and IDAInit to initialize solution *)
  (* Call IDASpgmr to specify the IDAS LINEAR SOLVER IDASPGMR *)
  (* Call IDABBDPrecInit to initialize the band-block-diagonal preconditioner.
     The half-bandwidths for the difference quotient evaluation are exact
     for the system Jacobian, but only a 5-diagonal band matrix is retained. *)
  let mudq = nsmxsub in
  let mldq = nsmxsub in
  let mukeep = 2 in
  let mlkeep = 2 in
  let maxl = 16 in
  let mem =
    Ida.(init
      (SStolerances (rtol,atol))
      ~lsolver:Spils.(solver (spgmr ~maxl uv)
                        (Ida_bbd.prec_left ~dqrely:zero
                                           Ida_bbd.({ mudq; mldq; mukeep; mlkeep })
                                           (reslocal data)))
      (res data)
      t0 uv uvp)
  in

  (* Initialize adjoint module. *)
  Adjoint.(init mem steps IPolynomial);

  (* Call IDACalcIC (with default options) to correct the initial values. *)
  let tout = ref 0.001 in
  Ida.calc_ic_ya_yd' mem ~varid:id !tout;

  if thispe = 0 then
    printf "\nStarting integration of the FORWARD problem\n\n"
  ;

  (* On PE 0, print heading, basic parameters, initial values. *)
  if thispe = 0 then
    print_header system_size maxl mudq mldq mukeep mlkeep rtol atol
  ;
  (* Call IDAS in tout loop, normal mode, and print selected output. *)
  let tret,_,_ = Adjoint.forward_normal mem tend uv uvp in

  print_output mem uv tret data comm;

  (* Print each PE's portion of the solution in a separate file. *)
  (* print_sol mem uv uvp data comm; *)

  (* On PE 0, print final set of statistics. *)
  if thispe = 0 then
    print_final_stats mem;

  (*******************************************************
  *                 ADJOINT                              *
  *******************************************************)
  if thispe = 0 then
    printf "\n\t\t BACKWARD problem\n";

  let uvB    = make local_N system_size comm 0. in
  let uvpB   = make local_N system_size comm 0. in
  let residB = make local_N system_size comm 0. in

  (*Get consistent IC *)
  set_initial_profiles_b (unvec uv) (unvec uvp)
    (unvec uvB) (unvec uvpB) (unvec residB) data;

  (* Call IDASpgmr to specify the IDAS LINEAR SOLVER IDASPGMR *)
  let maxl = 16 in
  let mudq = nsmxsub in
  let mldq = nsmxsub in
  let mukeep = 2 in
  let mlkeep = 2 in
  let indexB =
    Adjoint.(init_backward
       mem
       (SStolerances (rtol,atol))
       ~lsolver:Spils.(solver (spgmr ~maxl uvB)
                         (Idas_bbd.prec_left ~dqrely:zero
                                             Idas_bbd.({ mudq; mldq; mukeep; mlkeep })
                                             (resBlocal data)))
       (NoSens (resB data))
       ~varid:id
       tend uvB uvpB)
  in

  Adjoint.backward_normal mem tbegin;

  let _ = Adjoint.get indexB uvB uvpB in

  (* Print each PE's portion of solution in a separate file. *)
  (* PrintAdjSol(uvB, uvpB, data); *)

  (* On PE 0, print final set of statistics. *)
  if thispe = 0 then
    print_final_stats_b indexB


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
