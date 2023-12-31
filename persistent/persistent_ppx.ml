open Printf
open Ppxlib
open Ast_builder.Default
open ContainersLabels
open Ppx_deriving_tools
open Ppx_deriving_tools.Deriving_helper

let ext_structure_item ~name expand =
  let pattern =
    let open Ast_pattern in
    let extractor_in_let =
      pstr_value drop (value_binding ~pat:__ ~expr:__ ^:: nil)
    in
    pstr @@ extractor_in_let ^:: nil
  in
  let expand ~ctxt pat expr =
    let loc = Expansion_context.Extension.extension_point_loc ctxt in
    let rec rewrite e =
      match e.pexp_desc with
      | Pexp_fun (lab, default, pat, e) ->
          pexp_fun ~loc:e.pexp_loc lab default pat (rewrite e)
      | _ -> expand ~ctxt e
    in
    let expr = rewrite expr in
    [%stri let [%p pat] = [%e expr]]
  in
  Context_free.Rule.extension
    (Extension.V3.declare name Extension.Context.structure_item pattern
       expand)

let with_genname_field ~loc col body =
  [%expr
    let genname =
      match [%e col] with
      | "" -> fun n -> n
      | prefix -> fun n -> Printf.sprintf "%s.%s" prefix n
    in
    [%e body [%expr genname]]]

let with_genname_idx ~loc col body =
  [%expr
    let genname =
      match [%e col] with
      | "" -> fun i -> Printf.sprintf "_%i" i
      | prefix -> fun i -> Printf.sprintf "%s._%i" prefix i
    in
    [%e body [%expr genname]]]

let derive_scope_type =
  object (self)
    inherit deriving_type
    method name = "scope"

    method! derive_of_record
        : loc:location -> (label loc * Repr.type_expr) list -> core_type =
      fun ~loc fs ->
        let fs =
          List.map fs ~f:(fun (n, t) ->
              let loc = n.loc in
              let t = self#derive_of_type_expr ~loc t in
              {
                pof_desc = Otag (n, t);
                pof_loc = loc;
                pof_attributes = [];
              })
        in
        ptyp_object ~loc fs Closed

    method! derive_of_tuple
        : loc:location -> Repr.type_expr list -> core_type =
      fun ~loc ts ->
        let ts = List.map ts ~f:(self#derive_of_type_expr ~loc) in
        ptyp_tuple ~loc ts
  end

class virtual defined_via =
  object (self)
    method virtual via_name : string

    method derive_type_ref_name name lid =
      pexp_field ~loc:lid.loc
        (pexp_ident ~loc:lid.loc
           (map_loc (derive_of_longident self#via_name) lid))
        { txt = lident name; loc = lid.loc }
  end

let derive_scope =
  let match_table ~loc x f =
    match gen_pat_tuple ~loc "x" 2 with
    | p, [ t; c ] -> pexp_match ~loc x [ p --> f (t, c) ]
    | _, _ -> assert false
  in
  object (self)
    inherit deriving1
    inherit! defined_via
    method name = "scope"
    method via_name = "meta"

    method t ~loc name _t =
      let id = map_loc (derive_of_label derive_scope_type#name) name in
      let id = map_loc lident id in
      let scope = ptyp_constr ~loc id [] in
      [%type: string * string -> [%t scope]]

    method! derive_of_tuple ~loc ts x =
      match_table ~loc x @@ fun (tbl, col) ->
      with_genname_idx ~loc col @@ fun genname ->
      let es =
        List.mapi ts ~f:(fun idx t ->
            let idx = eint ~loc idx in
            self#derive_of_type_expr ~loc t
              [%expr [%e tbl], [%e genname] [%e idx]])
      in
      pexp_tuple ~loc es

    method! derive_of_record ~loc fs x =
      match_table ~loc x @@ fun (tbl, col) ->
      with_genname_field ~loc col @@ fun genname ->
      let fields =
        List.map fs ~f:(fun (n, t) ->
            let loc = n.loc in
            let col' = estring ~loc n.txt in
            let e =
              self#derive_of_type_expr ~loc t
                [%expr [%e tbl], [%e genname] [%e col']]
            in
            {
              pcf_desc = Pcf_method (n, Public, Cfk_concrete (Fresh, e));
              pcf_loc = loc;
              pcf_attributes = [];
            })
      in
      pexp_object ~loc (class_structure ~self:(ppat_any ~loc) ~fields)
  end

let derive_decode =
  object (self)
    inherit deriving1
    inherit! defined_via
    method via_name = "codec"
    method name = "decode"

    method t ~loc _name t =
      [%type: Sqlite3.Data.t array -> Persistent.Codec.ctx -> [%t t]]

    method! derive_of_tuple ~loc ts x =
      let n = List.length ts in
      let ps, e = gen_tuple ~loc "x" n in
      let e =
        List.fold_left2 (List.rev ps) (List.rev ts) ~init:e
          ~f:(fun next p t ->
            [%expr
              let [%p p] = [%e self#derive_of_type_expr ~loc t x] ctx in
              [%e next]])
      in
      [%expr fun ctx -> [%e e]]

    method! derive_of_record ~loc fs x =
      let ps, e = gen_record ~loc "x" fs in
      let e =
        List.fold_left2 (List.rev ps) (List.rev fs) ~init:e
          ~f:(fun next p (_, t) ->
            [%expr
              let [%p p] = [%e self#derive_of_type_expr ~loc t x] ctx in
              [%e next]])
      in
      [%expr fun ctx -> [%e e]]
  end

let derive_bind =
  object (self)
    inherit deriving1
    inherit! defined_via
    method via_name = "codec"
    method name = "bind"
    method t ~loc _name t = [%type: [%t t] Persistent.Codec.bind]

    method! derive_of_tuple ~loc ts x =
      let n = List.length ts in
      let p, es = gen_pat_tuple ~loc "x" n in
      let e =
        List.fold_left2 (List.rev es) (List.rev ts) ~init:[%expr ()]
          ~f:(fun next e t ->
            [%expr
              [%e self#derive_of_type_expr ~loc t e] ctx stmt;
              [%e next]])
      in
      [%expr fun ctx stmt -> [%e pexp_match ~loc x [ p --> e ]]]

    method! derive_of_record ~loc fs x =
      let p, es = gen_pat_record ~loc "x" fs in
      let e =
        List.fold_left2 (List.rev es) (List.rev fs) ~init:[%expr ()]
          ~f:(fun next e (_, t) ->
            [%expr
              [%e self#derive_of_type_expr ~loc t e] ctx stmt;
              [%e next]])
      in
      [%expr fun ctx stmt -> [%e pexp_match ~loc x [ p --> e ]]]
  end

let derive_columns =
  object (self)
    inherit deriving1
    inherit! defined_via
    method via_name = "codec"
    method name = "columns"

    method t ~loc _name _t =
      [%type: string -> Persistent.Codec.column list]

    method! derive_of_tuple ~loc ts x =
      with_genname_idx ~loc x @@ fun genname ->
      let es =
        List.mapi ts ~f:(fun i t ->
            let i = eint ~loc i in
            [%expr
              [%e
                self#derive_of_type_expr ~loc t
                  [%expr [%e genname] [%e i]]]])
      in
      [%expr Stdlib.List.flatten [%e pexp_list ~loc es]]

    method! derive_of_record ~loc fs x =
      with_genname_field ~loc x @@ fun genname ->
      let es =
        List.map fs ~f:(fun ((n : label loc), t) ->
            let loc = n.loc in
            let n = estring ~loc n.txt in
            let es =
              self#derive_of_type_expr ~loc t [%expr [%e genname] [%e n]]
            in
            [%expr
              Stdlib.List.map
                (fun col ->
                  { col with Persistent.Codec.field = Some [%e n] })
                [%e es]])
      in
      [%expr Stdlib.List.flatten [%e pexp_list ~loc es]]
  end

let derive_fields =
  object (self)
    inherit deriving1
    inherit! defined_via
    method via_name = "meta"
    method name = "fields"

    method t ~loc _name _t =
      [%type: string -> (Persistent.any_expr * string) list]

    method! derive_of_tuple ~loc ts x =
      with_genname_idx ~loc x @@ fun genname ->
      let es =
        List.mapi ts ~f:(fun i t ->
            let i = eint ~loc i in
            [%expr
              [%e
                self#derive_of_type_expr ~loc t
                  [%expr [%e genname] [%e i]]]])
      in
      [%expr Stdlib.List.flatten [%e pexp_list ~loc es]]

    method! derive_of_record ~loc fs x =
      with_genname_field ~loc x @@ fun genname ->
      let es =
        List.map fs ~f:(fun ((n : label loc), t) ->
            let n = estring ~loc:n.loc n.txt in
            [%expr
              [%e
                self#derive_of_type_expr ~loc t
                  [%expr [%e genname] [%e n]]]])
      in
      [%expr Stdlib.List.flatten [%e pexp_list ~loc es]]
  end

let derive_codec =
  object
    inherit deriving0
    method name = "codec"
    method t ~loc _name t = [%type: [%t t] Persistent.Codec.t]

    method! derive_of_tuple ~loc ts =
      let columns = derive_columns#derive_of_tuple ~loc ts [%expr x] in
      let decode = derive_decode#derive_of_tuple ~loc ts [%expr x] in
      let bind = derive_bind#derive_of_tuple ~loc ts [%expr x] in
      [%expr
        {
          Persistent.Codec.columns = (fun x -> [%e columns]);
          decode = (fun x -> [%e decode]);
          bind = (fun x -> [%e bind]);
        }]

    method! derive_of_record ~loc fs =
      let columns = derive_columns#derive_of_record ~loc fs [%expr x] in
      let decode = derive_decode#derive_of_record ~loc fs [%expr x] in
      let bind = derive_bind#derive_of_record ~loc fs [%expr x] in
      [%expr
        {
          Persistent.Codec.columns = (fun x -> [%e columns]);
          decode = (fun x -> [%e decode]);
          bind = (fun x -> [%e bind]);
        }]
  end

let derive_meta =
  object
    inherit deriving0 as super
    method name = "meta"

    method t ~loc _name t =
      let s =
        derive_scope_type#derive_of_type_expr ~loc (Repr.of_core_type t)
      in
      [%type: [%t s] Persistent.meta]

    method! derive_of_tuple ~loc ts =
      let scope = derive_scope#derive_of_tuple ~loc ts [%expr x] in
      let fields = derive_fields#derive_of_tuple ~loc ts [%expr x] in
      [%expr
        {
          Persistent.scope = (fun x -> [%e scope]);
          fields = (fun x -> [%e fields]);
        }]

    method! derive_of_record ~loc fs =
      let scope = derive_scope#derive_of_record ~loc fs [%expr x] in
      let fields = derive_fields#derive_of_record ~loc fs [%expr x] in
      [%expr
        {
          Persistent.scope = (fun x -> [%e scope]);
          fields = (fun x -> [%e fields]);
        }]

    method! generator ~ctxt tds =
      let scope = derive_scope_type#generator ~ctxt tds in
      let meta = super#generator ~ctxt tds in
      scope @ meta
  end

let codec = register' derive_codec
let meta = register' derive_meta

let extract_columns () =
  let open Ast_pattern in
  let col_many = pexp_tuple (many (pexp_ident __')) in
  let col = map1 (pexp_ident __') ~f:List.return in
  let cols = col_many ||| col in
  map1 cols
    ~f:
      (List.map ~f:(function
        | { txt = Lident txt; loc } -> { txt; loc }
        | _ -> failwith "expected a column"))

let primary_key =
  Attribute.declare_with_attr_loc "persistent.primary_key"
    Attribute.Context.type_declaration
    Ast_pattern.(single_expr_payload (extract_columns ()))
    (fun ~attr_loc cols -> attr_loc, cols)

let unique =
  Attribute.declare_with_attr_loc "persistent.unique"
    Attribute.Context.type_declaration
    Ast_pattern.(single_expr_payload (extract_columns ()))
    (fun ~attr_loc cols -> attr_loc, cols)

let table_args =
  let open Deriving.Args in
  empty +> arg "name" (estring __)

let _ =
  let resolve_names fields names =
    List.map names ~f:(fun name ->
        let f =
          List.find_opt fields ~f:(fun f ->
              String.equal f.pld_name.txt name.txt)
        in
        match f with
        | None -> error ~loc:name.loc "no such field"
        | Some f -> name, f.pld_type)
  in
  let extract_columns ~loc fs =
    [%expr
      let fs =
        [%e
          pexp_list ~loc
            (List.map ~f:(fun ({ txt; loc }, _) -> estring ~loc txt) fs)]
      in
      Stdlib.List.filter
        (fun col ->
          match col.Persistent.Codec.field with
          | None -> false
          | Some f -> Stdlib.List.mem f fs)
        columns]
  in
  let derive_table ~name:table_name ~pk ~unique
      (td, { Repr.name; params; shape = _; loc }) =
    let fields =
      match td.ptype_kind with
      | Ptype_record fs -> fs
      | _ -> error ~loc "not a record"
    in
    if not (List.is_empty params) then
      not_supported ~loc "type parameters";
    let table_name =
      match table_name, name.txt with
      | None, "t" ->
          error ~loc "missing table name, specify with ~name argument"
      | None, txt -> { loc = name.loc; txt }
      | Some txt, _ -> { loc = name.loc; txt }
    in
    let unique = Option.map (resolve_names fields) unique in
    let pk = resolve_names fields pk in
    let pk_type = ptyp_tuple ~loc (List.map pk ~f:snd) in
    let pk_project =
      [%expr
        fun x ->
          [%e
            pexp_tuple ~loc
              (List.map pk ~f:(fun ({ loc; txt }, _) ->
                   pexp_field ~loc [%expr x] { loc; txt = lident txt }))]]
    in
    let derive ?(name = name) what =
      let id = map_loc (derive_of_label what) name in
      pexp_ident ~loc (map_loc lident id)
    in
    let derive_pat ?(name = name) what =
      let id = map_loc (derive_of_label what) name in
      ppat_var ~loc id
    in
    let derive_type what =
      let id = map_loc (derive_of_label what) name in
      ptyp_constr ~loc (map_loc lident id) []
    in
    let table = pexp_ident ~loc (map_loc lident name) in
    let optionals =
      (* TODO: read optionals from fields as well *)
      match pk with
      | [ (n, t) ] -> (
          match t with [%type: int] -> [ n.txt ] | _ -> [])
      | _ -> []
    in
    let insert =
      let rev_fields = List.rev fields in
      let bind =
        List.fold_left rev_fields ~init:[%expr ()] ~f:(fun next f ->
            let e = pexp_ident ~loc (map_loc lident f.pld_name) in
            let bind x =
              derive_bind#derive_of_type_expr ~loc
                (Repr.of_core_type f.pld_type)
                x
            in
            let bind =
              if List.mem f.pld_name.txt optionals then
                [%expr
                  Persistent.Primitives.option_bind
                    (fun x -> [%e bind [%expr x]])
                    [%e e]]
              else bind e
            in
            [%expr
              [%e bind] ctx stmt;
              [%e next]])
      in
      let body =
        List.fold_left rev_fields
          ~init:
            [%expr
              fun () ->
                [%e bind];
                k ()]
          ~f:(fun body f ->
            let label =
              if List.mem f.pld_name.txt optionals then
                Optional f.pld_name.txt
              else Labelled f.pld_name.txt
            in
            pexp_fun ~loc label None (ppat_var ~loc f.pld_name) body)
      in
      [%expr fun ~ctx ~stmt k -> [%e body]]
    in
    [
      pstr_value ~loc Nonrecursive
        [
          value_binding ~loc ~pat:(ppat_var ~loc name)
            ~expr:
              [%expr
                let codec = [%e derive "codec"] in
                let meta = [%e derive "meta"] in
                let columns = codec.Persistent.Codec.columns "" in
                let unique_columns =
                  [%e
                    match unique with
                    | None -> [%expr None]
                    | Some unique ->
                        [%expr Some [%e extract_columns ~loc unique]]]
                in
                let primary_key = [%e pk_project] in
                let primary_key_columns = [%e extract_columns ~loc pk] in
                let primary_key_bind x =
                  [%e
                    derive_bind#derive_of_type_expr ~loc
                      (Repr.of_core_type pk_type)
                      [%expr x]]
                in
                ({
                   Persistent.table =
                     [%e estring ~loc:table_name.loc table_name.txt];
                   codec;
                   unique_columns;
                   primary_key_columns;
                   primary_key_bind;
                   primary_key;
                   fields = meta.fields "";
                   scope = meta.scope;
                   columns;
                 }
                  : ( [%t ptyp_constr ~loc (map_loc lident name) []],
                      [%t derive_type "scope"],
                      [%t pk_type] )
                    Persistent.table)];
        ];
      [%stri
        let [%p derive_pat "insert"] =
          Persistent.make_query_with
            ~sql:(Persistent.Sql.insert_sql [%e table])
            [%e insert]];
      [%stri
        let [%p derive_pat "upsert"] =
          Persistent.make_query_with
            ~sql:(Persistent.Sql.upsert_sql [%e table])
            [%e insert]];
      [%stri let [%p derive_pat "delete"] = Persistent.delete [%e table]];
      [%stri let [%p derive_pat "update"] = Persistent.update [%e table]];
    ]
  in
  Deriving.add "table"
    ~str_type_decl:
      (Deriving.Generator.V2.make ~deps:[ codec; meta ] table_args
         (fun ~ctxt (_rec_flag, type_decls) name ->
           try
             let loc = Expansion_context.Deriver.derived_item_loc ctxt in
             let str =
               List.flat_map type_decls ~f:(fun td ->
                   let repr = Repr.of_type_declaration td in
                   let pk =
                     match Attribute.get primary_key td with
                     | None -> error ~loc "missing @@primary_key"
                     | Some (_loc, pk) -> pk
                   in
                   let unique =
                     Option.map snd (Attribute.get unique td)
                   in
                   derive_table ~name ~pk ~unique (td, repr))
             in
             [%stri [@@@ocaml.warning "-39-11"]] :: str
           with Error (loc, msg) -> [ stri_error ~loc msg ]))

module Expr_form = struct
  let expand ~ctxt:_ (e : expression) =
    let rec rewrite e =
      let loc = e.pexp_loc in
      match e.pexp_desc with
      | Pexp_ident { txt = Lident "null"; _ } ->
          [%expr Persistent.E.null ()]
      | Pexp_ident { txt = Lident "="; _ } -> [%expr Persistent.E.( = )]
      | Pexp_ident { txt = Lident "&&"; _ } -> [%expr Persistent.E.( && )]
      | Pexp_ident { txt = Lident "||"; _ } -> [%expr Persistent.E.( || )]
      | Pexp_ident { txt = Lident ">"; _ } -> [%expr Persistent.E.( > )]
      | Pexp_ident { txt = Lident "<"; _ } -> [%expr Persistent.E.( < )]
      | Pexp_ident { txt = Lident "<="; _ } -> [%expr Persistent.E.( <= )]
      | Pexp_ident { txt = Lident ">="; _ } -> [%expr Persistent.E.( >= )]
      | Pexp_ident { txt = Lident "+"; _ } -> [%expr Persistent.E.( + )]
      | Pexp_ident { txt = Lident "-"; _ } -> [%expr Persistent.E.( - )]
      | Pexp_ident { txt = Lident "*"; _ } -> [%expr Persistent.E.( * )]
      | Pexp_ident { txt = Lident "/"; _ } -> [%expr Persistent.E.( / )]
      | Pexp_ident _ -> e
      | Pexp_field (e, { txt = Lident n; loc = nloc }) ->
          pexp_send ~loc:nloc (rewrite e) { txt = n; loc = nloc }
      | Pexp_apply (f, args) -> (
          match e with
          | [%expr [%e? scope] #. [%e? field]] ->
              let field =
                match field.pexp_desc with
                | Pexp_ident { txt = Lident txt; loc } -> { loc; txt }
                | _ -> error ~loc:field.pexp_loc "not an identifier"
              in
              [%expr
                Persistent.E.of_opt [%e scope] (fun scope ->
                    [%e pexp_send ~loc:field.loc [%expr scope] field])]
          | [%expr [%e? nullable] |? [%e? default]] ->
              [%expr
                Persistent.E.coalesce [%e rewrite nullable]
                  [%e rewrite default]]
          | [%expr to_nullable [%e? e]] ->
              [%expr Persistent.E.to_nullable [%e rewrite e]]
          | _ ->
              pexp_apply ~loc (rewrite f)
                (List.map args ~f:(fun (l, e) -> l, rewrite e)))
      | Pexp_constant (Pconst_integer _) ->
          [%expr Persistent.E.int [%e e]]
      | Pexp_constant (Pconst_char _) -> [%expr Persistent.E.char [%e e]]
      | Pexp_constant (Pconst_string (_, _, _)) ->
          [%expr Persistent.E.string [%e e]]
      | Pexp_constant (Pconst_float (_, _)) ->
          [%expr Persistent.E.float [%e e]]
      | Pexp_construct ({ txt = Lident "true"; loc }, None) ->
          [%expr Persistent.E.bool true]
      | Pexp_construct ({ txt = Lident "false"; loc }, None) ->
          [%expr Persistent.E.bool false]
      | Pexp_ifthenelse (c, t, None) ->
          [%expr Persistent.E.iif' [%e rewrite c] [%e rewrite t]]
      | Pexp_ifthenelse (c, t, Some e) ->
          [%expr
            Persistent.E.iif [%e rewrite c] [%e rewrite t] [%e rewrite e]]
      | Pexp_field _
      | Pexp_let (_, _, _)
      | Pexp_function _
      | Pexp_fun (_, _, _, _)
      | Pexp_match (_, _)
      | Pexp_try (_, _)
      | Pexp_tuple _ | Pexp_construct _
      | Pexp_variant (_, _)
      | Pexp_record (_, _)
      | Pexp_setfield (_, _, _)
      | Pexp_array _
      | Pexp_sequence (_, _)
      | Pexp_while (_, _)
      | Pexp_for (_, _, _, _, _)
      | Pexp_constraint (_, _)
      | Pexp_coerce (_, _, _)
      | Pexp_send (_, _)
      | Pexp_new _
      | Pexp_setinstvar (_, _)
      | Pexp_override _
      | Pexp_letmodule (_, _, _)
      | Pexp_letexception (_, _)
      | Pexp_assert _ | Pexp_lazy _
      | Pexp_poly (_, _)
      | Pexp_object _
      | Pexp_newtype (_, _)
      | Pexp_pack _
      | Pexp_open (_, _)
      | Pexp_letop _ | Pexp_extension _ | Pexp_unreachable ->
          error ~loc "this expression is not supported"
    in
    try rewrite e with Error (loc, msg) -> pexp_error ~loc msg

  let ext =
    let pattern =
      let open Ast_pattern in
      single_expr_payload __
    in
    Context_free.Rule.extension
      (Extension.V3.declare "expr" Extension.Context.expression pattern
         expand)

  let ext' = ext_structure_item ~name:"expr" expand
end

module Query_form = struct
  module Scope_structure = struct
    type t = location * syn

    and syn =
      | Pat_name of label loc
      | Pat_tuple of t list
      | Pat_record of (label loc * t) list

    let rec build arg body = function
      | loc, Pat_name label ->
          [%expr
            let [%p ppat_var ~loc label] = [%e arg] in
            [%e body]]
      | _loc, Pat_tuple ps ->
          List.foldi ps ~init:body ~f:(fun next i ((loc, _) as p) ->
              let arg =
                pexp_send ~loc arg { txt = sprintf "_%i" (i + 1); loc }
              in
              build arg next p)
      | _loc, Pat_record fs ->
          List.fold_left fs ~init:body
            ~f:(fun next (name, ((loc, _) as p)) ->
              let arg = pexp_send ~loc arg name in
              build arg next p)

    let name ~loc txt = loc, Pat_name { loc; txt }
    let tuple ~loc xs = loc, Pat_tuple xs

    let rec of_expression e =
      let loc = e.pexp_loc in
      match e.pexp_desc with
      | Pexp_ident { txt = Lident txt; loc = loc' } ->
          loc, Pat_name { txt; loc = loc' }
      | Pexp_ident { txt = Ldot (_, txt); loc = loc' } ->
          loc, Pat_name { txt; loc = loc' }
      | Pexp_tuple es -> loc, Pat_tuple (List.map es ~f:of_expression)
      | Pexp_record (fs, None) ->
          let f = function
            | { txt = Lident txt; loc }, e ->
                { txt; loc }, of_expression e
            | _ -> error ~loc "invalid pattern"
          in
          loc, Pat_record (List.map fs ~f)
      | _ -> error ~loc "invalid pattern"

    let rec of_pattern p =
      let loc = p.ppat_loc in
      match p.ppat_desc with
      | Ppat_var lab -> loc, Pat_name lab
      | Ppat_tuple es -> loc, Pat_tuple (List.map es ~f:of_pattern)
      | Ppat_record (fs, _) ->
          let f = function
            | { txt = Lident txt; loc }, e -> { txt; loc }, of_pattern e
            | _ -> error ~loc "invalid pattern"
          in
          loc, Pat_record (List.map fs ~f)
      | _ -> error ~loc "invalid pattern"
  end

  let rec unroll acc e =
    match e.pexp_desc with
    | Pexp_sequence (a, b) -> unroll (a :: acc) b
    | _ -> e :: acc

  let pexp_opt ~loc e =
    match e with None -> [%expr None] | Some e -> [%expr Some [%e e]]

  let name_of e =
    let p = Scope_structure.of_expression e in
    match p with
    | _, Pat_name { loc; txt } -> p, Some (estring ~loc txt)
    | _ -> p, None

  let pexp_slot' ~loc names e =
    let names =
      Option.value names ~default:(Scope_structure.name ~loc "t")
    in
    [%expr
      fun [@ocaml.warning "-27-26"] __scope ->
        [%e Scope_structure.build [%expr __scope] e names]]

  let make_scope ~loc names fs =
    let fields =
      List.map fs ~f:(fun (_, (n, e)) ->
          let ns = estring ~loc:n.loc n.txt in
          let e = [%expr Persistent.E.as_col __t [%e ns] [%e e]] in
          {
            pcf_desc = Pcf_method (n, Public, Cfk_concrete (Fresh, e));
            pcf_loc = loc;
            pcf_attributes = [];
          })
    in
    pexp_slot' ~loc names
      [%expr
        fun (__t, __p) ->
          [%e
            pexp_object ~loc
              (class_structure ~self:(ppat_any ~loc) ~fields)]]

  let expand_select' ~ctxt ~loc ?(make_scope = make_scope)
      (alias, names, prev) fs =
    let fs =
      List.map fs ~f:(fun (n, e) ->
          match e with
          | [%expr nullable [%e? e]] ->
              `null, (n, Expr_form.expand ~ctxt e)
          | e -> `not_null, (n, Expr_form.expand ~ctxt e))
    in
    let ps, e = gen_tuple ~loc "col" (List.length fs) in
    let x, xs =
      match List.combine ps fs with
      | [] -> assert false
      | x :: xs -> x, xs
    in
    let make txt (pat, (nullable, (n, e))) =
      let name = estring ~loc:n.loc n.txt in
      let exp =
        match nullable with
        | `null -> [%expr Persistent.P.get_opt ~name:[%e name] [%e e]]
        | `not_null -> [%expr Persistent.P.get ~name:[%e name] [%e e]]
      in
      binding_op ~loc ~op:{ loc; txt } ~pat ~exp
    in
    let e =
      pexp_letop ~loc
        (letop ~body:e ~let_:(make "let+" x)
           ~ands:(List.map xs ~f:(make "and+")))
    in
    let e =
      [%expr
        Persistent.P.select' ?n:[%e pexp_opt ~loc alias] [%e prev]
          [%e make_scope ~loc names fs]
          [%e
            pexp_slot' ~loc names
              [%expr
                let open Persistent.P in
                [%e e]]]]
    in
    Some (Scope_structure.name ~loc "t"), alias, e

  let rec expand' ?names ?prev ~ctxt e =
    let rec rewrite ((alias, names, prev) as here) q =
      let loc = q.pexp_loc in
      match q with
      | [%expr from [%e? id]] ->
          let names, alias' = name_of id in
          let alias = Option.or_ alias ~else_:alias' in
          let alias = Option.value alias ~default:[%expr "t"] in
          ( Some names,
            Some alias,
            [%expr Persistent.Q.from ~n:[%e alias] [%e id]] )
      | [%expr where [%e? e]] ->
          ( names,
            alias,
            [%expr
              Persistent.Q.where ?n:[%e pexp_opt ~loc alias] [%e prev]
                [%e pexp_slot' ~loc names (Expr_form.expand ~ctxt e)]] )
      | [%expr order_by [%e? fs]] ->
          let fs =
            let fs =
              match fs.pexp_desc with Pexp_tuple fs -> fs | _ -> [ fs ]
            in
            List.map fs ~f:(function
              | [%expr desc [%e? e]] ->
                  [%expr Persistent.Q.desc [%e Expr_form.expand ~ctxt e]]
              | [%expr asc [%e? e]] ->
                  [%expr Persistent.Q.asc [%e Expr_form.expand ~ctxt e]]
              | e ->
                  error ~loc:e.pexp_loc
                    "should have form 'desc e' or 'asc e'")
          in
          let e = pexp_list ~loc fs in
          ( names,
            alias,
            [%expr
              Persistent.Q.order_by ?n:[%e pexp_opt ~loc alias] [%e prev]
                [%e pexp_slot' ~loc names e]] )
      | [%expr left_join [%e? q] [%e? e]] ->
          let aalias = alias in
          let qnames, balias, q = expand' ~ctxt q in
          let qnames =
            Option.value qnames
              ~default:(Scope_structure.name ~loc:q.pexp_loc "right")
          in
          let names =
            Option.value names ~default:(Scope_structure.name ~loc "t")
          in
          let names = Scope_structure.tuple ~loc [ names; qnames ] in
          let alias = Some [%expr "q"] in
          ( Some names,
            alias,
            [%expr
              Persistent.Q.left_join ?na:[%e pexp_opt ~loc aalias]
                ?nb:[%e pexp_opt ~loc balias] [%e prev] [%e q]
                [%e
                  pexp_slot' ~loc (Some names) (Expr_form.expand ~ctxt e)]]
          )
      | [%expr query [%e? ocamlish]] ->
          let names =
            Option.value names ~default:(Scope_structure.name ~loc "t")
          in
          Some names, alias, [%expr [%e ocamlish] [%e prev]]
      | [%expr [%e? name] = [%e? rhs]] ->
          let _name, _alias, rhs = rewrite here rhs in
          let name, alias = name_of name in
          Some name, alias, rhs
      | { pexp_desc = Pexp_tuple xs; _ }
      | [%expr select [%e? { pexp_desc = Pexp_tuple xs; _ }]] ->
          let fs =
            List.mapi xs ~f:(fun i x ->
                let n =
                  { txt = sprintf "_%i" (i + 1); loc = x.pexp_loc }
                in
                n, x)
          in
          expand_select' ~ctxt ~loc here fs
      | { pexp_desc = Pexp_record (fs, None); _ }
      | [%expr select [%e? { pexp_desc = Pexp_record (fs, None); _ }]] ->
          let fs =
            List.map fs ~f:(fun (n, x) ->
                match n.txt with
                | Lident txt -> { txt; loc = n.loc }, x
                | _ -> error ~loc "invalid select")
          in
          expand_select' ~ctxt ~loc here fs
      | [%expr select [%e? e]] ->
          let fs = [ { txt = "c"; loc = e.pexp_loc }, e ] in
          let make_scope ~loc names fs =
            let n, e =
              match fs with [ (_, x) ] -> x | _ -> assert false
            in
            let ns = estring ~loc:n.loc n.txt in
            pexp_slot' ~loc names
              [%expr
                fun (__t, __p) -> Persistent.E.as_col __t [%e ns] [%e e]]
          in
          expand_select' ~ctxt ~loc ~make_scope here fs
      | [%expr
          let [%p? pat] = [%e? ocamlish] in
          [%e? next]] ->
          let name, alias, next = rewrite here next in
          ( name,
            alias,
            [%expr
              let [%p pat] = [%e ocamlish] in
              [%e next]] )
      | [%expr fun [%p? names] -> [%e? e]] ->
          let names = Scope_structure.of_pattern names in
          let name, alias, expr =
            expand' ~names ~ctxt ~prev:[%expr prev] e
          in
          name, alias, [%expr fun prev -> [%e expr]]
      | e ->
          Format.printf "%a@." Ppxlib_ast.Pprintast.expression e;
          error ~loc "unknown query form"
    in
    match List.rev (unroll [] e) with
    | [] ->
        error
          ~loc:(Expansion_context.Extension.extension_point_loc ctxt)
          "empty query"
    | q :: qs ->
        let loc = Expansion_context.Extension.extension_point_loc ctxt in
        let prev = Option.value prev ~default:[%expr ()] in
        List.fold_left qs
          ~init:(rewrite (None, names, prev) q)
          ~f:(fun (names, alias, prev) e ->
            let names, alias, e = rewrite (alias, names, prev) e in
            names, alias, e)

  let expand ~ctxt e =
    try
      let loc = Expansion_context.Extension.extension_point_loc ctxt in
      match e with
      | [%expr
          let [%p? p] = [%e? e] in
          [%e? body]] ->
          let _, _, e = expand' ~ctxt e in
          [%expr
            let [%p p] = [%e e] in
            [%e body]]
      | e ->
          let _, _, e = expand' ~ctxt e in
          e
    with Error (loc, msg) -> pexp_error ~loc msg

  let ext =
    let pattern =
      let open Ast_pattern in
      single_expr_payload __
    in
    Context_free.Rule.extension
      (Extension.V3.declare "query" Extension.Context.expression pattern
         expand)

  let ext' = ext_structure_item ~name:"query" expand
end

let () =
  Driver.register_transformation
    ~rules:
      [ Expr_form.ext; Expr_form.ext'; Query_form.ext; Query_form.ext' ]
    "persistent_ppx"
