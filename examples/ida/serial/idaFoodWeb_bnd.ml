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
 * Example program for IDA: Food web problem.
 *
 * This example program (serial version) uses the IDABAND linear
 * solver, and IDACalcIC for initial condition calculation.
 *
 * The mathematical problem solved in this example is a DAE system
 * that arises from a system of partial differential equations after
 * spatial discretization. The PDE system is a food web population
 * model, with predator-prey interaction and diffusion on the unit
 * square in two dimensions. The dependent variable vector is:
 *
 *         1   2         ns
 *   c = (c , c ,  ..., c  ) , ns = 2 * np
 *
 * and the PDE's are as follows:
 *
 *     i             i      i
 *   dc /dt = d(i)*(c    + c  )  +  R (x,y,c)   (i = 1,...,np)
 *                   xx     yy       i
 *
 *              i      i
 *   0 = d(i)*(c    + c  )  +  R (x,y,c)   (i = np+1,...,ns)
 *              xx     yy       i
 *
 *   where the reaction terms R are:
 *
 *                   i             ns         j
 *   R  (x,y,c)  =  c  * (b(i)  + sum a(i,j)*c )
 *    i                           j=1
 *
 * The number of species is ns = 2 * np, with the first np being
 * prey and the last np being predators. The coefficients a(i,j),
 * b(i), d(i) are:
 *
 *  a(i,i) = -AA   (all i)
 *  a(i,j) = -GG   (i <= np , j >  np)
 *  a(i,j) =  EE   (i >  np, j <= np)
 *  all other a(i,j) = 0
 *  b(i) = BB*(1+ alpha * x*y + beta*sin(4 pi x)*sin(4 pi y)) (i <= np)
 *  b(i) =-BB*(1+ alpha * x*y + beta*sin(4 pi x)*sin(4 pi y)) (i  > np)
 *  d(i) = DPREY   (i <= np)
 *  d(i) = DPRED   (i > np)
 *
 * The various scalar parameters required are set using top-level let
 * bindings or directly in routine init_user_data. In this program,
 * np = 1, ns = 2. The boundary conditions are homogeneous Neumann:
 * normal derivative = 0.
 *
 * A polynomial in x and y is used to set the initial values of the
 * first np variables (the prey variables) at each x,y location,
 * while initial values for the remaining (predator) variables are
 * set to a flat value, which is corrected by calc_ic_ya_yd'_init.
 *
 * The PDEs are discretized by central differencing on a MX by MY
 * mesh.
 *
 * The DAE system is solved by IDA using the IDABAND linear solver.
 * Output is printed at t = 0, .001, .01, .1, .4, .7, 1.
 * -----------------------------------------------------------------
 * References:
 * [1] Peter N. Brown and Alan C. Hindmarsh,
 *     Reduced Storage Matrix Methods in Stiff ODE systems, Journal
 *     of Applied Mathematics and Computation, Vol. 31 (May 1989),
 *     pp. 40-91.
 *
 * [2] Peter N. Brown, Alan C. Hindmarsh, and Linda R. Petzold,
 *     Using Krylov Methods in the Solution of Large-Scale
 *     Differential-Algebraic Systems, SIAM J. Sci. Comput., 15
 *     (1994), pp. 1467-1488.
 *
 * [3] Peter N. Brown, Alan C. Hindmarsh, and Linda R. Petzold,
 *     Consistent Initial Condition Calculation for Differential-
 *     Algebraic Systems, SIAM J. Sci. Comput., 19 (1998),
 *     pp. 1495-1512.
 * -----------------------------------------------------------------
 *)

open Sundials

let printf = Printf.printf

let sundials_270_or_later =
  match Config.sundials_version with
  | 2,5,_ | 2,6,_ -> false
  | _ -> true

(* Problem Constants. *)
let nprey       = 1                     (* No. of prey (= no. of predators). *)
let num_species = 2*nprey
let pi          = 3.1415926535898
let fourpi      = 4.0*.pi
let mx          = 20                    (* MX = number of x mesh points *)
let my          = 20                    (* MY = number of y mesh points *)
let nsmx        = num_species * mx
let neq         = num_species * mx * my
let aa          = 1.0                   (* Coefficient in above eqns. for a *)
let ee          = 10000.                (* Coefficient in above eqns. for a *)
let gg          = 0.5e-6                (* Coefficient in above eqns. for a *)
let bb          = 1.0                   (* Coefficient in above eqns. for b *)
let dprey       = 1.0                   (* Coefficient in above eqns. for d *)
let dpred       = 0.05                  (* Coefficient in above eqns. for d *)
let alpha       = 50.                   (* Coefficient alpha in above eqns. *)
let beta        = 1000.                 (* Coefficient beta in above eqns. *)
let ax          = 1.0                   (* Total range of x variable *)
let ay          = 1.0                   (* Total range of y variable *)
let rtol        = 1.e-5                 (* Relative tolerance *)
let atol        = 1.e-5                 (* Absolute tolerance *)
let nout        = 6                     (* Number of output times *)
let tmult       = 10.0                  (* Multiplier for tout values *)
let tadd        = 0.3                   (* Increment for tout values *)

(* User-defined vector and accessor functions: index and ij_v.  These are
 * defined in order to express the underlying 3-D structure of the dependent
 * variable vector from its underlying 1-D storage (an N_Vector).  index i j k
 * returns the index corresponding to the location in vv corresponding to
 * species index is = k, x-index ix = i, and y-index jy = j.  ij_v returns a
 * slice of vv corresponding to x-index ix = i, and y-index jy = j, and species
 * index anywhere between 0 and num_species.  *)
let index i j k = i*num_species + j*nsmx + k
let ij_v (v : RealArray.t) i j =
  (* v is type annotated so that the layout of the bigarray is fixed.  This
     ensures that the compiler can inline accesses to the bigarray elements. *)
  let i0 = index i j 0
  and iend = index i j num_species in
  Bigarray.Array1.sub v i0 (iend - i0)

type user_data =
  { neq   : int;
    ns    : int;
    np    : int;
    mx    : int;
    my    : int;
    dx    : float;
    dy    : float;
    acoef : Matrix.ArrayDense.t;
    cox   : float array;
    coy   : float array;
    bcoef : float array;
    rates : RealArray.t
  }

(* init_user_data: Load problem constants in webdata (of type user_data).  *)
let init_user_data () =
  let webdata =
    { neq   = neq;
      mx    = mx;
      my    = my;
      ns    = num_species;
      np    = nprey;
      dx    = ax /. float_of_int (mx-1);
      dy    = ay /. float_of_int (my-1);
      acoef = Matrix.ArrayDense.create num_species num_species;
      cox   = Array.make num_species 0.;
      coy   = Array.make num_species 0.;
      bcoef = Array.make num_species 0.;
      rates = RealArray.create neq;
    } in
  (* Set up shorthands. *)
  let acoef = webdata.acoef
  and bcoef = webdata.bcoef
  and cox = webdata.cox
  and coy = webdata.coy
  and dx = webdata.dx
  and dy = webdata.dy
  and np = webdata.np
  in
  (* Set up the coefficients a and b, and others found in the equations. *)
  let np = np
  and dx2 = dx *. dx
  and dy2 = dy *. dy in

  let set = Matrix.ArrayDense.set in
  for i = 0 to np-1 do
    (* Fill in the portion of acoef in the four quadrants, row by row. *)
    for j = 0 to np-1 do
      set acoef (np+j) i      (-. gg);
      set acoef j      (i+np)      ee;
      set acoef j      i           0.;
      set acoef (np+j) (i+np)      0.;
    done;

    (* Reset the diagonal elements of acoef to -AA.  *)
    set acoef i i (-. aa);
    set acoef (i+np) (i+np) (-. aa);

    (* Set coefficients for b and diffusion terms.  *)
    bcoef.(i) <- bb; bcoef.(i+np) <- -. bb;
    cox.(i) <- dprey /. dx2; cox.(i+np) <- dpred /. dx2;
    coy.(i) <- dprey /. dy2; coy.(i+np) <- dpred /. dy2
  done;
  webdata

(* web_rates: Evaluate reaction rates at a given spatial point.
 * At a given (x,y), evaluate the array of ns reaction terms R. *)
let web_rates webdata x y ((cxy : RealArray.t), cxy_off)
                          ((ratesxy : RealArray.t), ratesxy_off) =
  let acoef = RealArray2.unwrap webdata.acoef
  and bcoef = webdata.bcoef in

  for is = 0 to num_species-1 do
    (* ratesxy.{is} <- dotprod cxy (Directdensematrix.column acoef is) *)
    ratesxy.{ratesxy_off + is} <- 0.;
    for j = 0 to num_species-1 do
      ratesxy.{ratesxy_off + is} <- ratesxy.{ratesxy_off + is}
                                  +. cxy.{cxy_off + j} *. acoef.{is, j}
    done
  done;

  let fac = 1. +. alpha*.x*.y +. beta*.sin(fourpi*.x)*.sin(fourpi*.y) in

  for is = 0 to num_species-1 do
    ratesxy.{ratesxy_off + is} <- cxy.{cxy_off + is}*.( bcoef.(is)*.fac
                                    +. ratesxy.{ratesxy_off + is} )
  done

(* fweb: Rate function for the food-web problem.
 * This routine computes the right-hand sides of the system equations,
 * consisting of the diffusion term and interaction term.
 * The interaction term is computed by the function WebRates.  *)
let fweb webdata _ c (crate : RealArray.t) =
  let cox = webdata.cox
  and coy = webdata.coy in
  (* Loop over grid points, evaluate interaction vector (length ns), form
     diffusion difference terms, and load crate. *)
  for jy = 0 to my-1 do
    let yy = webdata.dy *. float_of_int jy
    and idyu = if jy <> my-1 then nsmx else -nsmx
    and idyl = if jy <> 0    then nsmx else -nsmx
    in
    for jx = 0 to mx-1 do
      let xx = webdata.dx *. float_of_int jx
      and idxu = if jx <> mx-1 then num_species else -num_species
      and idxl = if jx <> 0    then num_species else -num_species in

      (* Get interaction vector at this grid point. *)
      web_rates webdata xx yy (c, index jx jy 0)
                              (webdata.rates, index jx jy 0);

      (* Loop over species, do differencing, load crate segment. *)
      let off = index jx jy 0 in
      for is = 0 to num_species-1 do
        (* Differencing in y. *)
        let dcyli = c.{off + is} -. c.{off + (is - idyl)}
        and dcyui = c.{off + idyu + is} -. c.{off + is} in
        (* Differencing in x. *)
        let dcxli = c.{off + is} -. c.{off + (is - idxl)}
        and dcxui = c.{off + (is + idxu)} -. c.{off + is} in
        (* Compute the crate values at (xx,yy). *)
        crate.{off + is} <- (coy.(is) *. (dcyui -. dcyli)
                            +. cox.(is) *. (dcxui -. dcxli)
                            +. webdata.rates.{index jx jy is})
      done
    done
  done

(* System residual function for predator-prey system.  This routine calls fweb
 * to get all the right-hand sides of the equations, then loads the residual
 * vector accordingly, using c' in the case of prey species.  *)
let resweb webdata t c (c' : RealArray.t) res =
  let np = webdata.np in

  (* Call Fweb to set res to vector of right-hand sides. *)
  fweb webdata t c res;

  (* Loop over all grid points, setting residual values appropriately
     for differential or algebraic components. *)
  for jy = 0 to my-1 do
    let yloc = nsmx * jy in
    for jx = 0 to mx-1 do
      let loc = yloc + num_species * jx in
      for is = 0 to num_species-1 do
        if is < np
        then res.{loc+is} <- c'.{loc+is} -. res.{loc+is}
        else res.{loc+is} <- -. res.{loc+is}
      done
    done
  done

let set_initial_profiles webdata c c' id =
  (* Loop over grid, load c values and id values.  *)
  for jy = 0 to my-1 do
    let y = webdata.dy *. float_of_int jy
    and yloc = nsmx * jy in
    for jx = 0 to mx-1 do
      let x = webdata.dx *. float_of_int jx in
      let xyfactor = 16.0*.x*.(1.-.x)*.y*.(1.-.y) in
      let xyfactor = xyfactor *. xyfactor
      and loc = yloc + num_species*jx in
      for is = 0 to num_species-1 do
        if is < webdata.np
        then (c.{loc+is} <- 10.0 +. float_of_int (is+1) *. xyfactor;
              id.{loc+is} <- Ida.VarId.differential)
        else (c.{loc+is} <- 1.0e5;
              id.{loc+is} <- Ida.VarId.algebraic)
      done
    done
  done;

  (* Set c' for the prey by calling the function fweb. *)
  fweb webdata 0. c c';

  (* Set c' for predators to 0. *)
  for jy = 0 to my-1 do
    let yloc = nsmx * jy in
    for jx = 0 to mx-1 do
      let loc = yloc + num_species * jx in
      for is = webdata.np to num_species-1 do
        c'.{loc+is} <- 0.0
      done
    done
  done

let idaband =
  match Config.sundials_version with 2,_,_ -> "IDABAND" | _ -> "BAND"

(* Print first lines of output (problem description) *)
let print_header mu ml rtol atol =
  printf "\nidaFoodWeb_bnd: Predator-prey DAE serial example problem for IDA \n\n";
  printf "Number of species ns: %d" num_species;
  printf "     Mesh dimensions: %d x %d" mx my;
  printf "     System size: %d\n" neq;
  printf "Tolerance parameters:  rtol = %g   atol = %g\n" rtol atol;
  printf "Linear solver: %s,  Band parameters mu = %d, ml = %d\n" idaband mu ml;
  printf "CalcIC called to correct initial predator concentrations.\n\n";
  printf "-----------------------------------------------------------\n";
  printf "  t        bottom-left  top-right";
  printf "    | nst  k      h\n";
  printf "-----------------------------------------------------------\n\n";
;;
(*
 * PrintOutput: Print output values at output time t = tt.
 * Selected run statistics are printed.  Then values of the concentrations
 * are printed for the bottom left and top right grid points only.
 *)

let print_output mem c t =
  let kused = Ida.get_last_order mem
  and nst   = Ida.get_num_steps mem
  and hused = Ida.get_last_step mem
  and c_bl = ij_v c 0 0
  and c_tr = ij_v c (mx-1) (my-1) in

  if sundials_270_or_later
  then printf "%8.2e %12.4e %12.4e   | %3d  %1d %12.4e\n"
         t c_bl.{0} c_tr.{0} nst kused hused
  else printf "%8.2e %12.4e %12.4e   | %3d  %1d %12.4e\n"
         t c_bl.{0} c_tr.{1} nst kused hused;
  for i = 1 to num_species-1 do
    printf "         %12.4e %12.4e   |\n" c_bl.{i} c_tr.{i}
  done;
  printf "\n"

(*
 * PrintFinalStats: Print final run data contained in iopt.
 *)

let print_final_stats mem =
  let open Ida in
  let nst   = get_num_steps mem
  and nni   = get_num_nonlin_solv_iters mem
  and nre   = get_num_res_evals mem
  and netf  = get_num_err_test_fails mem
  and ncfn  = get_num_nonlin_solv_conv_fails mem
  and nje   = Dls.get_num_jac_evals mem
  and nreLS = Dls.get_num_lin_res_evals mem in

  printf "-----------------------------------------------------------\n";
  printf "Final run statistics: \n\n";
  printf "Number of steps                    = %d\n" nst;
  printf "Number of residual evaluations     = %d\n" (nre+nreLS);
  printf "Number of Jacobian evaluations     = %d\n" nje;
  printf "Number of nonlinear iterations     = %d\n" nni;
  printf "Number of error test failures      = %d\n" netf;
  printf "Number of nonlinear conv. failures = %d\n" ncfn

let main () =
  let webdata = init_user_data ()
  and c  = RealArray.create neq
  and c' = RealArray.create neq
  and id = RealArray.create neq in
  set_initial_profiles webdata c c' id;

  (* Set remaining inputs to IDAInit. *)
  let t0 = 0. in

  (* Wrap c and c' in nvectors.  Operations performed on the wrapped
     representation affect the originals c and c'.  *)
  let wc = Nvector_serial.wrap c
  and wc' = Nvector_serial.wrap c'
  in

  (* Call IDACreate and IDABand to initialize IDA including the linear
     solver. *)
  let mu = nsmx and ml = nsmx in
  let m = Matrix.band ~smu:(mu+ml) ~mu ~ml neq in
  let mem = Ida.(init (SStolerances (rtol, atol))
                      ~lsolver:Dls.(solver (band wc m))
                      (resweb webdata) t0 wc wc') in
  let tout1 = 0.001 in
  Ida.calc_ic_ya_yd' mem ~varid:(Nvector_serial.wrap id) tout1;

  (* Print heading, basic parameters, and initial values. *)
  print_header mu ml rtol atol;
  print_output mem c 0.;

  (* Loop over iout, call IDASolve (normal mode), print selected output. *)
  let tout = ref tout1 in
  for iout = 1 to nout do
    let tret, _ = Ida.solve_normal mem !tout wc wc' in
    print_output mem c tret;
    if iout < 3 then tout := !tout *. tmult
    else tout := !tout +. tadd
  done;

  print_final_stats mem

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
