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

[@@@ocaml.warning "-7"]

(**
 Custom tags for the ocamldoc comments:
    @cvode          link to Sundials CVODE documentation
    @cvodes         link to Sundials CVODES documentation
    @arkode         link to Sundials ARKODE documentation
    @ida            link to Sundials IDA documentation
    @idas           link to Sundials IDAS documentation
    @kinsol         link to Sundials KINSOL documentation
 *)

let cvode_doc_root = ref CVODE_DOC_ROOT
let cvodes_doc_root = ref CVODES_DOC_ROOT
let arkode_doc_root = ref ARKODE_DOC_ROOT
let ida_doc_root = ref IDA_DOC_ROOT
let idas_doc_root = ref IDAS_DOC_ROOT
let kinsol_doc_root = ref KINSOL_DOC_ROOT

let mathjax_url = ref MATHJAX_URL (* directory containing MathJax.js *)

let bp = Printf.bprintf
let bs = Buffer.add_string

type custom_type =
    Simple of (string -> string)
  | Full of (Buffer.t -> Odoc_info.text -> unit)

let broken_sundials_link div_class doc_root page anchor title =
  Printf.sprintf
    "<li><div class=\"sundials %s\">\
      <span class=\"seesundials\">See sundials: </span>\
      <a href=\"%s%s.html%s\">%s</a></div></li>"
    div_class doc_root page anchor title

let sundials_link div_class _doc_root _page _anchor title =
  Printf.sprintf
    "<li><div class=\"sundials %s\">\
      <span class=\"seesundials\">See sundials: </span>%s</div></li>"
    div_class title

module Generator (G : Odoc_html.Html_generator) =
struct
  class html =
  object(self)
    inherit G.html as super

    val rex = Str.regexp "<\\([^#>]*\\)\\(#[^)]*\\)?> \\(.*\\)"

    val variables = [
      ("version", let major, minor, patch, _binding = Sundials_configuration.version in
                  Printf.sprintf "%d.%d.%d" major minor patch)
    ]

    method private split_text (t:Odoc_info.text) =
      let s = Odoc_info.text_string_of_text t in
      if not (Str.string_match rex s 0) then
        failwith "Bad parse!"
      else
        let page = Str.matched_group 1 s
        and anchor = try
              Str.matched_group 2 s
            with Not_found -> ""
        and title = Str.matched_group 3 s
        in
      (page, anchor, title)

    method private html_of_missing t =
      let (_page, _anchor, title) = self#split_text t in
      Printf.sprintf
        "<div class=\"sundials\"><span class=\"seesundials\">See sundials: </span>%s</div>"
        title

    method private html_of_cvode t =
      let (page, anchor, title) = self#split_text t in
      sundials_link "cvode" !cvode_doc_root page anchor title

    method private html_of_cvodes t =
      let (page, anchor, title) = self#split_text t in
      sundials_link "cvodes" !cvodes_doc_root page anchor title

    method private html_of_arkode t =
      let (page, anchor, title) = self#split_text t in
      sundials_link "arkode" !arkode_doc_root page anchor title

    method private html_of_ida t =
      let (page, anchor, title) = self#split_text t in
      sundials_link "ida" !ida_doc_root page anchor title

    method private html_of_idas t =
      let (page, anchor, title) = self#split_text t in
      sundials_link "idas" !idas_doc_root page anchor title

    method private html_of_kinsol t =
      let (page, anchor, title) = self#split_text t in
      sundials_link "kinsol" !kinsol_doc_root page anchor title

    val divrex = Str.regexp " *\\(open\\|close\\) *\\(.*\\)"

    method private html_of_div s =
      let baddiv s = (Odoc_info.warning (Printf.sprintf
            "div must be followed by 'open' or 'close', not '%s'!" s); "") in
      if not (Str.string_match divrex s 0) then baddiv s
      else
        match Str.matched_group 1 s with
        | "open" ->
            let attrs = try Str.matched_group 2 s with Not_found -> "" in
            Printf.sprintf "<div %s>" attrs
        | "close" -> "</div>"
        | s -> baddiv s

    method private html_of_var s =
      let var = Str.replace_first (Str.regexp " +$") ""
                  (Str.replace_first (Str.regexp "^ +") "" s) in
      try
        List.assoc var variables
      with Not_found ->
        (Odoc_info.warning (Printf.sprintf "Variable '%s' is not defined." var); "")

    method private html_of_img s =
      Printf.sprintf "<a href=\"%s\"><img src=\"%s\"></a>" s s

    method private html_of_openfile s =
      let var = Str.replace_first (Str.regexp " +$") ""
                  (Str.replace_first (Str.regexp "^ +") "" s) in
      Printf.sprintf "<a href=\"%s\">%s</a>" var var

    method private html_of_cconst s =
      let var = Str.replace_first (Str.regexp " +$") ""
                  (Str.replace_first (Str.regexp "^ +") "" s) in
      Printf.sprintf "<span class=\"cconst\">(%s)</span>" var

    method private html_of_color s =
      let ss = Str.bounded_split (Str.regexp "[ \t\n]+") s 2 in
      match ss with
      | [x] ->
          (Odoc_info.warning (Printf.sprintf "No color given ('%s')." x); x)
      | [color; text] ->
          Printf.sprintf "<span style=\"color: %s;\">%s</span>" color text
      | _ -> assert false

    method html_of_raised_exceptions b l =
      match l with
        [] -> ()
      | (s, t) :: [] ->
          bs b "<div class=\"raisedexceptions\">";
          bp b "<span class=\"raises\">%s</span> <code>%s</code> "
            Odoc_messages.raises
            s;
          self#html_of_text b t;
          bs b "</div>\n"
      | _ ->
          bs b "<div class=\"raisedexceptions\">";
          bp b "<span class=\"raises\">%s</span><ul>" Odoc_messages.raises;
          List.iter
            (fun (ex, desc) ->
              bp b "<li><code>%s</code> " ex ;
              self#html_of_text b desc;
              bs b "</li>\n"
            )
            l;
          bs b "</ul></div>\n"

    method html_of_author_list b l =
      match l with
        [] -> ()
      | _ ->
          bp b "<div class=\"authors\">";
          bp b "<b>%s:</b> " Odoc_messages.authors;
          self#html_of_text b [Odoc_info.Raw (String.concat ", " l)];
          bs b "</div>\n"

    val mutable custom_functions =
      ([] : (string * custom_type) list)

    method private html_of_warning b t =
      bs b "<div class=\"warningbox\">";
      self#html_of_text b t;
      bs b "</div>"

    method private html_of_custom_text b tag text =
      try
        match List.assoc tag custom_functions, text with
        | (Simple f, [Odoc_info.Raw s]) -> Buffer.add_string b (f s)
        | (Simple _, _) ->
            Odoc_info.warning (Printf.sprintf 
              "custom tags (%s) must be followed by plain text." tag)
        | (Full f, _) -> f b text
      with
        Not_found -> Odoc_info.warning (Odoc_messages.tag_not_handled tag)

    (* Import MathJax (http://www.mathjax.org/) to render mathematics in
       function comments. *)
    method init_style =
      super#init_style;
      style <- style ^
                "<script type=\"text/x-mathjax-config\">\n" ^
                "   MathJax.Hub.Config({tex2jax: {inlineMath: [['$','$']]}});\n" ^
                "</script>" ^
                "<script type=\"text/javascript\"\n" ^
                Printf.sprintf
                  "        src=\"%s/MathJax.js?config=TeX-AMS-MML_HTMLorMML\">\n"
                  !mathjax_url ^
                "</script>\n"

    method html_of_Latex b s =
      Buffer.add_string b s

    initializer
      tag_functions <- ("cvode",    self#html_of_cvode) :: tag_functions;
      tag_functions <- ("nocvode",  self#html_of_missing) :: tag_functions;
      tag_functions <- ("cvodes",   self#html_of_cvodes) :: tag_functions;
      tag_functions <- ("nocvodes", self#html_of_missing) :: tag_functions;
      tag_functions <- ("arkode",   self#html_of_arkode) :: tag_functions;
      tag_functions <- ("noarkode", self#html_of_missing) :: tag_functions;
      tag_functions <- ("ida",      self#html_of_ida) :: tag_functions;
      tag_functions <- ("noida",    self#html_of_missing) :: tag_functions;
      tag_functions <- ("idas",     self#html_of_idas) :: tag_functions;
      tag_functions <- ("noidas",   self#html_of_missing) :: tag_functions;
      tag_functions <- ("kinsol",   self#html_of_kinsol) :: tag_functions;
      tag_functions <- ("nokinsol", self#html_of_missing) :: tag_functions;

      custom_functions <- ("div",      Simple self#html_of_div)      ::
                          ("var",      Simple self#html_of_var)      ::
                          ("color",    Simple self#html_of_color)    ::
                          ("img",      Simple self#html_of_img)      ::
                          ("cconst",   Simple self#html_of_cconst)   ::
                          ("openfile", Simple self#html_of_openfile) ::
                          ("warning", Full self#html_of_warning)     ::
                          custom_functions

  end
end

let _  = Odoc_html.charset := "utf-8"

let option_cvode_doc_root =
  ("-cvode-doc-root", Arg.String (fun d -> cvode_doc_root := d), 
   "<dir>  specify the root url for the Sundials CVODE documentation.")
let option_cvodes_doc_root =
  ("-cvodes-doc-root", Arg.String (fun d -> cvodes_doc_root := d), 
   "<dir>  specify the root url for the Sundials CVODES documentation.")
let option_arkode_doc_root =
  ("-arkode-doc-root", Arg.String (fun d -> arkode_doc_root := d), 
   "<dir>  specify the root url for the Sundials ARKODE documentation.")
let option_ida_doc_root =
  ("-ida-doc-root", Arg.String (fun d -> ida_doc_root := d), 
   "<dir>  specify the root url for the Sundials IDA documentation.")
let option_idas_doc_root =
  ("-idas-doc-root", Arg.String (fun d -> idas_doc_root := d), 
   "<dir>  specify the root url for the Sundials IDAS documentation.")
let option_kinsol_doc_root =
  ("-kinsol-doc-root", Arg.String (fun d -> kinsol_doc_root := d), 
   "<dir>  specify the root url for the Sundials KINSOL documentation.")
let option_mathjax_url =
  ("-mathjax", Arg.String (fun d -> mathjax_url := d), 
   "<url>  specify the root url for MathJax.")

let _ =
  Odoc_args.add_option option_cvode_doc_root;
  Odoc_args.add_option option_cvodes_doc_root;
  Odoc_args.add_option option_arkode_doc_root;
  Odoc_args.add_option option_ida_doc_root;
  Odoc_args.add_option option_idas_doc_root;
  Odoc_args.add_option option_kinsol_doc_root;
  Odoc_args.add_option option_mathjax_url;
  Odoc_args.extend_html_generator (module Generator : Odoc_gen.Html_functor)

