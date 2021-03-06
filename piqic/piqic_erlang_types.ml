(*pp camlp4o -I `ocamlfind query piqi.syntax` pa_labelscope.cmo pa_openin.cmo *)
(*
   Copyright 2009, 2010, 2011 Anton Lavrik

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*)

 
(*
 * generation of Erlang -record(...) and -type(...) definitions
 *)

open Piqi_common
open Iolist


(* toplevel Erlang modname for the module which is currently being compiled *)
(* TODO: this is a dirty method for sharing settings across all
 * piqic_erlang_* modules *)
let top_modname = ref ""
let type_prefix = ref ""
let any_erlname = ref ""
let string_type :T.erlang_string_type ref = ref `binary


let scoped_name name = !type_prefix ^ name


let piqdef_erlname = function
  | `record t -> some_of t.R#erlang_name
  | `variant t -> some_of t.V#erlang_name
  | `enum t -> some_of t.E#erlang_name
  | `alias t -> some_of t.A#erlang_name
  | `list t -> some_of t.L#erlang_name
  | _ ->
      (* this function will be called only for named types (i.e. piqdefs) *)
      assert false


let gen_deftype parent erlang_name =
  let erlang_name = some_of erlang_name in
  match parent with
    | Some (`import x) -> (* imported name *)
        let piqi = some_of x.Import#piqi in
        let type_prefix = some_of piqi.P#erlang_type_prefix in
        (type_prefix ^ erlang_name)
    | _ -> (* local name *)
        scoped_name erlang_name


let rec gen_piqtype t erlang_type = 
  match erlang_type with
    | Some x -> x
    | None ->
        match t with
          | `int -> "integer"
          | `float -> "float"
          | `bool -> "boolean"
          | `string | `word | `text -> "string"
          | `binary -> "binary"
          | `any ->
              if !Piqic_common.is_self_spec
              then scoped_name !any_erlname
              else "piqi_any"
          | `record r -> gen_deftype r.R#parent r.R#erlang_name
          | `variant v -> gen_deftype v.V#parent v.V#erlang_name
          | `enum e -> gen_deftype e.E#parent e.E#erlang_name
          | `list l -> gen_deftype l.L#parent l.L#erlang_name
          | `alias a -> gen_aliastype a


and gen_aliastype a =
  let open Alias in
  match some_of a.parent with
    | `piqi p when is_boot_piqi p ->
        gen_typeref a.typeref ?erlang_type:a.erlang_type
    | _ ->
        gen_deftype a.parent a.erlang_name


and gen_typeref ?erlang_type (t:T.typeref) =
  gen_piqtype (piqtype t) erlang_type


let ios_gen_in_typeref t =
  let rec unalias = function
    | `alias t when t.A#erlang_type = None ->
        unalias t.A#typeref
    | t -> t
  in
  (* un-alias to avoid Dialyzer complaints like this one: "... states that the
   * function might also return string() but the inferred return is binary()" *)
  let n = gen_typeref (unalias t) in
  (* recognized the fact that strings are actually parsed as binaries *)
  let n =
    if n <> "string"
    then n
    else
      match !string_type with
        | `binary -> "binary"
        | `list -> "string"
  in
  ios n ^^ ios "()"


let ios_gen_out_typeref ?erlang_type t =
  let n = gen_typeref ?erlang_type t in
  (* allow more flexible typing in certain cases: loosen type restrictions for
   * convenience *)
  match n with
    | "string" -> ios "string() | binary()"
    | "float" -> ios "number()"
    | _ -> ios n ^^ ios "()"


let gen_field_type fl ft =
  match ft with
    | None -> ios "boolean()"; (* flags are represented as booleans *)
    | Some ft ->
      let deftype = ios_gen_out_typeref ft in
      match fl with
        | `required -> deftype
        | `optional -> deftype
        | `repeated -> ios "[" ^^ deftype ^^ ios "]"


let erlname_of name typeref =
  match name, typeref with
    | Some n, _ -> n
    | None, Some t -> piqdef_erlname t
    | _ -> assert false


let erlname_of_field f =
  let open F in erlname_of f.erlang_name f.typeref


let erlname_of_option o =
  let open O in erlname_of o.erlang_name o.typeref


let gen_field f = 
  let open F in
  let fdef = iol (* field definition *)
    [
      ios (erlname_of_field f);
      (* initialize repreated fields as [] *)
      (if f.mode = `repeated then ios " = []" else ios "");
      ios " :: ";
      gen_field_type f.mode f.typeref;
    ]
  in fdef


let gen_record r =
  let name = some_of r.R#erlang_name in
  let rdef = iol
    [
      ios "-record("; ios (scoped_name name); ios ", ";
      ios "{"; indent;
      iod ",\n    " (List.map gen_field r.R#field);
      unindent; eol;
      ios "}).";
      eol;
    ]
  in rdef


let gen_type name type_expr =
  iol [
    ios "-type("; ios (scoped_name name); ios "() :: "; type_expr; ios ").";
    eol;
  ]

let gen_record_type r =
  let name = some_of r.R#erlang_name in
  gen_type name (iol [ ios "#"; ios (scoped_name name); ios "{}"])


let gen_option o =
  let open Option in
  match o.erlang_name, o.typeref with
    | None, Some (`variant v) | None, Some (`enum v) ->
        ios (scoped_name (some_of v.V#erlang_name)) ^^ ios "()"
    | _, Some t ->
        let n = erlname_of_option o in
        iol [
          ios "{";
            ios n;
            ios ", ";
            ios_gen_out_typeref t;
          ios "}";
        ]
    | Some _, None ->
        let n = erlname_of_option o in
        ios n
    | None, None -> assert false


let gen_variant v =
  let open Variant in
  let name = some_of v.erlang_name in
  let type_expr = iol [
    indent; ios "  ";
    iod "\n    | " (List.map gen_option v.option);
    unindent; eol;
  ]
  in
  gen_type name type_expr


let gen_alias a =
  let open Alias in
  let name = some_of a.erlang_name in
  let type_expr = ios_gen_out_typeref a.typeref ?erlang_type:a.erlang_type in
  gen_type name type_expr


let gen_list l =
  let open L in
  let name = some_of l.erlang_name in
  let type_expr =
    iol [
      ios "["; ios_gen_out_typeref l.typeref; ios "]";
    ]
  in
  gen_type name type_expr


let gen_def = function
  | `record t -> gen_record t
  | `variant t | `enum t -> gen_variant t
  | `list t -> gen_list t
  | `alias t -> gen_alias t


let gen_def x =
  let open Alias in
  match x with
    | `alias a ->
        (* skip generation of aliases from the boot module *)
        (match some_of a.parent with
          | `piqi p when is_boot_piqi p -> []
          | _ -> [gen_def x]
        )
    | _ ->
        [gen_def x]


let gen_defs (defs:T.piqdef list) =
  let records = flatmap (function `record x -> [x] | _ -> []) defs in
  let record_types = List.map gen_record_type records in
  let defs = flatmap gen_def defs in
  let code = iol [
    iol defs; eol;
    iol record_types; eol;
  ]
  in code


let gen_import x =
  let open Import in
  let piqi = some_of x.piqi in
  iol [
    ios "-include("; ioq (some_of piqi.P#erlang_module ^ ".hrl"); ios ").";
    eol;
  ]


let gen_imports l =
  let l = List.map gen_import l in
  let piqtype_incl = 
    if !Piqic_common.depends_on_piq_any && not !Piqic_common.is_self_spec
    then ios "-include(\"piqi_piqi.hrl\").\n\n"
    else iol []
  in
  iol [
    piqtype_incl;
    iol l;
  ]


let gen_piqi (piqi:T.piqi) =
  iol [
    gen_imports piqi.P#resolved_import;
    gen_defs piqi.P#resolved_piqdef;
  ]

