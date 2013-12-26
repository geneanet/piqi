(*pp camlp4o -I `ocamlfind query piqi.syntax` pa_labelscope.cmo pa_openin.cmo *)
(*
   Copyright 2009, 2010, 2011, 2012, 2013 Anton Lavrik

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
 * This module contain functionality that is used by various parts of
 * piqi compilers.
 *)

module T = Piqi_piqi


module Record = T.Record
module Field = T.Field
module Variant = T.Variant
module Option = T.Option
module Enum = T.Enum
module Alias = T.Alias


module Import = T.Import
module Any = T.Any


module R = Record
module F = Field
module V = Variant
module O = Option
module E = Enum
module A = Alias
module L = T.Piqi_list
module P = T.Piqi


module U = Piqi_util


module Iolist = Piqi_iolist
open Iolist


module Idtable = Piqi_db.Idtable


(* indexes of Piqi module contents *)
type index = {
    i_piqi: T.piqi;
    import: Import.t Idtable.t;  (* import name -> Import.t *)
    typedef: T.typedef Idtable.t;  (* typedef name -> Typedef.t *)
}


type context = {
    (* the module being processed *)
    piqi: T.piqi;
    (* index of the piqi module being compiled *)
    index: index;

    (* indication whether the module that is being processed is a Piqi
     * self-spec, i.e. the module's name is "piqi" or it includes another module
     * named "piqi" *)
    is_self_spec: bool;

    (* original modules being compiled (imported modules ++ [piqi]) *)
    modules: T.piqi list;

    (* index of imported modules: #piqi.module -> #index{} *)
    module_index: index Idtable.t;
}


(*
 * Commonly used functions
 *)

let some_of = function
  | Some x -> x
  | None -> assert false


let gen_code = function
  | None -> assert false
  | Some code -> ios (Int32.to_string code)

(* polymorphic variant name starting with a ` *)
let gen_pvar_name name =
  ios "`" ^^ ios name


(*
 * set ocaml names if not specified by user
 *)

(* command-line flags *)
let flag_normalize_names = ref false


(* ocaml name of piqi name *)
let ocaml_name n =
  let n =
    if !flag_normalize_names
    then Piqi_name.normalize_name n
    else n
  in
  U.dashes_to_underscores n


let ocaml_lcname n = (* lowercase *)
  String.uncapitalize (ocaml_name n)


let ocaml_ucname n = (* uppercase *)
  String.capitalize (ocaml_name n)


let mlname n =
  Some (ocaml_lcname n)


(* variant of mlname for optional names *)
let mlname_opt n =
  match n with
    | None -> n
    | Some n -> mlname n


let mlname_field x =
  let open Field in (
    if x.ocaml_array && x.mode <> `repeated
    then Piqi_common.error x ".ocaml-array flag can be used only with repeated fields";

    if x.ocaml_optional && x.mode <> `optional
    then Piqi_common.error x ".ocaml-optional flag can be used only with optional fields";

    if x.ocaml_name = None then x.ocaml_name <- mlname_opt x.name
  )


let mlname_record x =
  let open Record in
  (if x.ocaml_name = None then x.ocaml_name <- mlname x.name;
   List.iter mlname_field x.field)


let mlname_option x =
  let open Option in
  if x.ocaml_name = None then x.ocaml_name <- mlname_opt x.name


let mlname_variant x =
  let open Variant in
  (if x.ocaml_name = None then x.ocaml_name <- mlname x.name;
   List.iter mlname_option x.option)


let mlname_enum x =
  let open Enum in
  (if x.ocaml_name = None then x.ocaml_name <- mlname x.name;
   List.iter mlname_option x.option)


let mlname_alias x =
  let open Alias in
  if x.ocaml_name = None then x.ocaml_name <- mlname x.name


let mlname_list x =
  let open L in
  if x.ocaml_name = None then x.ocaml_name <- mlname x.name


let mlname_typedef = function
  | `record x -> mlname_record x
  | `variant x -> mlname_variant x
  | `enum x -> mlname_enum x
  | `alias x -> mlname_alias x
  | `list x -> mlname_list x


let mlname_func x =
  let open T.Func in
  if x.ocaml_name = None then x.ocaml_name <- mlname x.name


let mlname_import import =
  let open Import in
  begin
    if import.name = None
    then import.name <- Some import.modname;

    if import.ocaml_name = None
    then import.ocaml_name <- Some (ocaml_ucname (some_of import.name))
  end


let mlmodname n =
  let n = Piqi_name.get_local_name n in (* cut module path *)
  Some (ocaml_ucname n ^ "_piqi")


let mlname_piqi (piqi:T.piqi) =
  let open P in
  begin
    (* NOTE: modname is always define in "piqi compile" output *)
    if piqi.ocaml_module = None
    then piqi.ocaml_module <- mlmodname (some_of piqi.modname);

    (* naming function parameters first, because otherwise they will be
     * overriden in mlname_defs *)
    List.iter mlname_func piqi.P#func;
    List.iter mlname_typedef piqi.P#typedef;
    List.iter mlname_import piqi.P#import;
  end


let typedef_name = function
  | `record x -> x.R#name
  | `variant x -> x.V#name
  | `enum x -> x.E#name
  | `alias x -> x.A#name
  | `list x -> x.L#name


let typedef_mlname = function
  | `record t -> some_of t.R#ocaml_name
  | `variant t -> some_of t.V#ocaml_name
  | `enum t -> some_of t.E#ocaml_name
  | `alias t -> some_of t.A#ocaml_name
  | `list t -> some_of t.L#ocaml_name


(* check whether the piqi module is a self-specification, i.e. piqi.piqi or
 * piqi.X.piqi
 *
 * XXX: this check is an approximation of the orignal criteria that says a
 * module is a self-spec if it is named piqi or includes a module named piqi. We
 * can't know this for sure, because information about included modules is, by
 * design, not preserved in "piqi compile" output *)
let is_self_spec piqi =
  let basename = Piqi_name.get_local_name (some_of piqi.P#modname) in
  match U.string_split basename '.' with
    | "piqi"::_ ->
        true
    | _ ->
        false


(* check whether the piqi module depends on "piqi-any" type (i.e. one of its
 * definitions has piqi-any as field/option/alias type *)
let depends_on_piqi_any (piqi: T.piqi) =
  let typedef_depends_on_piqi_any x =
    let is_any x = (x = "piqi-any") in
    let is_any_opt = function
      | Some x -> is_any x
      | None -> false
    in
    match x with
      | `record x -> List.exists (fun x -> is_any_opt x.F#typename) x.R#field
      | `variant x -> List.exists (fun x -> is_any_opt x.O#typename) x.V#option
      | `list x -> is_any x.L#typename
      | `alias x -> is_any_opt x.A#typename
      | `enum _ -> false
  in
  List.exists typedef_depends_on_piqi_any piqi.P#typedef


let load_self_spec () =
  let self_spec_bin = List.hd Piqi_piqi.piqi in
  let buf = Piqirun.init_from_string self_spec_bin in
  T.parse_piqi buf


let is_builtin_alias x =
    (* presence of piqi_type field means this alias typedef corresponds to one
     * of built-in types *)
    x.A#piqi_type <> None


let make_idtable l =
    List.fold_left (fun accu (k, v) -> Idtable.add accu k v) Idtable.empty l


(* index typedefs by name *)
let index_typedefs l =
  make_idtable (List.map (fun x -> typedef_name x, x) l)


let make_import_name x =
  match x.Import#name with
    | None -> x.Import#modname
    | Some n -> n


(* index imports by name *)
let index_imports l =
    make_idtable (List.map (fun x -> make_import_name x, x) l)


(* generate an index of all imports and definitions of a given module *)
let index_module piqi =
  {
      i_piqi = piqi;
      import = index_imports piqi.P#import;
      typedef = index_typedefs piqi.P#typedef;
  }


(* make an index of module name -> index *)
let make_module_index piqi_list =
  make_idtable (List.map (fun x -> some_of x.P#modname, index_module x) piqi_list)


let option_to_list = function
  | None -> []
  | Some x -> [x]


(* TODO: match this function in Erlang *)
let get_used_typenames typedef =
  let l =
    match typedef with
      | `record x ->
          U.flatmap (fun x -> option_to_list x.F#typename) x.R#field
      | `variant x ->
          U.flatmap (fun x -> option_to_list x.O#typename) x.V#option
      | `alias x ->
          (* NOTE: alias typename is undefined for lowest-level built-in types *)
          option_to_list x.A#typename
      | `list x ->
          [x.L#typename]
      | `enum _ ->
          []
  in
  U.uniq l


let rec get_used_builtin_typedefs typedefs builtins_index =
  if typedefs = []
  then []
  else
    let typenames = U.uniq (U.flatmap get_used_typenames typedefs) in
    let builtin_typenames = List.filter (Idtable.mem builtins_index) typenames in
    let builtin_typedefs = List.map (Idtable.find builtins_index) builtin_typenames in
    (* get built-in types' dependencies (that are also built-in types) -- usually
     * no more than 2-3 recursion steps is needed *)
    let res = (get_used_builtin_typedefs builtin_typedefs builtins_index) @ builtin_typedefs in
    U.uniqq res


(* append the list of built-in typedefs that are actually referenced by the
 * module *)
let add_builtin_typedefs piqi builtins_index =
  (* exclude builtin typedefs that are masked by the local typedefs *)
  let typedef_names = List.map typedef_name piqi.P#typedef in
  let builtins_index = List.fold_left Idtable.remove builtins_index typedef_names in
  let used_builtin_typedefs = get_used_builtin_typedefs piqi.P#typedef builtins_index in
  (* change the module as if the built-ins were defined locally *)
  P#{
    piqi with
    typedef = used_builtin_typedefs @ piqi.P#typedef
  }


let init piqi_list =
  List.iter mlname_piqi piqi_list;

  (* the module being compiled is the last element of the list; preceding
   * modules are imported dependencies *)
  let l = List.rev piqi_list in
  let piqi = List.hd l in
  let imports = List.rev (List.tl l) in

  let is_self_spec = is_self_spec piqi in
  let self_spec =
    if is_self_spec
    then piqi
    else (
      let piqi = load_self_spec () in
      mlname_piqi piqi;
      piqi
    )
  in
  let builtin_typedefs =
    if is_self_spec
    then
      (* for self-specs, all build-in types should be defined inside
       * XXX: remove unused built-in typedefs from generated self-spec? *)
      []
    else
      List.filter
        (function
          | `alias a -> is_builtin_alias a
          | _ -> false
        )
        self_spec.P#typedef
  in
  let builtins_index = index_typedefs builtin_typedefs in
  let piqi = add_builtin_typedefs piqi builtins_index in
  let imports = List.map (fun x -> add_builtin_typedefs x builtins_index) imports in

  (* index the compiled module's contents *)
  let index = index_module piqi in

  (* index imported modules *)
  let mod_index = make_module_index imports in
  {
    piqi = piqi;
    index = index;

    is_self_spec = is_self_spec;

    modules = piqi_list;
    module_index = mod_index;
  }


let switch_context context piqi =
  if context.piqi == piqi
  then context  (* already current => no-op *)
  else
    let index = Idtable.find context.module_index (some_of piqi.P#modname) in
    {
      context with
      piqi = piqi;
      index = index;
    }


(* the name of the top-level module being compiled *)
let top_modname context =
  some_of context.piqi.P#ocaml_module


let scoped_name context name =
  top_modname context ^ "." ^ name


let gen_parent_mod import =
  match import with
    | None -> iol []
    | Some x ->
        let ocaml_modname = some_of x.Import#ocaml_name in
        ios ocaml_modname ^^ ios "."


let resolve_import context import =
  Idtable.find context.module_index import.Import#modname


let resolve_local_typename ?import index name =
  let typedef = Idtable.find index.typedef name in
  (import, index.i_piqi, typedef)


(* resolve type name to its type definition and the module where it was defined
 * and the import its module was imported with *)
let resolve_typename_ext context typename =
  let index = context.index in
  match Piqi_name.split_name typename with
    | None, name ->  (* local type *)
        (* NOTE: this will also resolve built-in types *)
        resolve_local_typename index name
    | Some import_name, name ->  (* imported type *)
        let import = Idtable.find index.import import_name in
        let imported_index = resolve_import context import in
        resolve_local_typename imported_index name ~import


(* resolve type name to its type definition and the module where it was defined
 *)
let resolve_typename context typename =
  let import, parent_piqi, typedef = resolve_typename_ext context typename in
  (parent_piqi, typedef)


(* unwind aliases to the lowest-level non-alias typedef or one of the built-in
 * primitive Piqi types *)
type resolved_type = [ T.typedef | T.piqi_type]

let rec unalias context typedef :(T.piqi * resolved_type) =
  match typedef with
    | `alias {A.typename = Some typename} ->
        let parent_piqi, aliased_typedef = resolve_typename context typename in
        let parent_context = switch_context context parent_piqi in
        unalias parent_context aliased_typedef
    | `alias {A.piqi_type = Some piqi_type} ->
        context.piqi, (piqi_type :> resolved_type)
    | _ ->
        context.piqi, (typedef :> resolved_type)



let mlname_of context ocaml_name typename =
  match ocaml_name, typename with
    | Some n, _ -> n
    | None, Some typename  ->
        let parent_piqi, typedef = resolve_typename context typename in
        typedef_mlname typedef
    | _ ->
        assert false


let mlname_of_field context x =
  let open F in
  mlname_of context x.ocaml_name x.typename


let mlname_of_option context x =
  let open O in
  mlname_of context x.ocaml_name x.typename


let gen_builtin_type_name ?(ocaml_type: string option) (piqi_type :T.piqi_type) =
  match ocaml_type with
    | Some x -> x
    | None ->
        match piqi_type with
          | `int -> "int"
          | `float -> "float"
          | `bool -> "bool"
          | `string | `binary -> "string"
          | `any ->
              (* must be handled separately *)
              assert false


(* TODO: rename Erlang functions to match these function names *)
let typedef_can_be_protobuf_packed context typedef =
  let piqi, resolved_type = unalias context typedef in
  match resolved_type with
    | `int | `float | `bool -> true
    | `enum _ -> true  (* enum values can be packed in Protobuf *)
    | _ -> false


let type_can_be_protobuf_packed context typename =
  let parent_piqi, typedef = resolve_typename context typename in
  let parent_context = switch_context context parent_piqi in
  typedef_can_be_protobuf_packed parent_context typedef


(* custom types handling: used by piqic_ocaml_out, piqic_ocaml_in *)
let gen_convert_value typename ocaml_type direction value =
  match typename, ocaml_type with
    | Some typename, Some ocaml_type -> (* custom OCaml type *)
        iol [
          ios "(";
            ios ocaml_type;
            ios direction;
            ios typename;
            ios "("; value; ios ")";
          ios ")"
        ]
    | _ ->
        value


let get_default_wire_type piqi_type =
  match piqi_type with
    | `int -> `zigzag_varint
    | `float -> `fixed64
    | `bool -> `varint
    | _ -> `block


let gen_wire_type_name piqi_type wire_type =
  let wire_type =
    match wire_type with
      | Some x -> x
      | None ->
          get_default_wire_type piqi_type
  in
  match wire_type with
    | `varint -> "varint"
    | `zigzag_varint -> "zigzag_varint"
    | `fixed32 -> "fixed32"
    | `fixed64 -> "fixed64"
    | `signed_varint -> "signed_varint"
    | `signed_fixed32 -> "signed_fixed32"
    | `signed_fixed64 -> "signed_fixed64"
    | `block -> "block"


(* this is similar to unalias, but instead of returning resolved_type it returns
 * resolved protobuf wire type *)
let rec get_wire_type context typename =
  let parent_piqi, typedef = resolve_typename context typename in
  let parent_context = switch_context context parent_piqi in
  get_typedef_wire_type parent_context typedef

and get_typedef_wire_type context typedef =
  match typedef with
    | `alias {A.protobuf_wire_type = Some wire_type} ->
        (* NOTE: top-level aliases override protobuf_wire_type for lower-level
         * aliases *)
        Some wire_type
    | `alias {A.typename = Some typename} ->
        get_wire_type context typename
    | `alias {A.piqi_type = Some piqi_type} ->
        Some (get_default_wire_type piqi_type)
    | _ ->
        None


(* gen wire type width in bits if it is a fixed-sized type *)
let gen_wire_type_width wt =
  match wt with
    | `fixed32 | `signed_fixed32 -> "32"
    | `fixed64 | `signed_fixed64 -> "64"
    | _ -> ""


(* calculates and generates the width of a packed wire element in bits:
 * generated value can be 32, 64 or empty *)
let gen_elem_wire_width context typename is_packed =
  let open L in
  if not is_packed
  then ""
  else
    match get_wire_type context typename with
      | None -> ""
      | Some x ->
          gen_wire_type_width x


let gen_field_mode context f =
  let open F in
  match f.mode with
    | `required -> "required"
    | `optional when f.default <> None && (not f.ocaml_optional) ->
        "required" (* optional + default *)
    | `optional -> "optional"
    | `repeated ->
        let mode =
          if f.protobuf_packed
          then "packed_repeated"
          else "repeated"
        in
        if f.ocaml_array
        then
          let typename = some_of f.typename in  (* always defined for repeated fields *)
          let width = gen_elem_wire_width context typename f.protobuf_packed in
          mode ^ "_array" ^ width
        else
          mode


(* generate: (packed_)?(list|array|array32|array64) *)
let gen_list_repr context l =
  let open L in
  let packed = ios (if l.protobuf_packed then "packed_" else "") in
  let repr =
    if l.ocaml_array
    then ios "array" ^^ ios (gen_elem_wire_width context l.typename l.protobuf_packed)
    else ios "list"
  in
  packed ^^ repr


(* TODO *)
let gen_cc s =
  ios ""
