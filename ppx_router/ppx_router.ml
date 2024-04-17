open ContainersLabels
open Ppxlib
open Ast_builder.Default

let patt_and_expr ~loc label = pvar ~loc label, evar ~loc label

let collect_params_rev ~loc:_ uri =
  let rec aux acc = function
    | [] -> acc
    | "" :: xs -> aux acc xs
    | x :: xs -> (
        match String.chop_prefix x ~pre:":" with
        | None -> aux (`path x :: acc) xs
        | Some name -> aux (`param name :: acc) xs)
  in
  aux [] (Uri.path uri |> String.split_on_char ~by:'/')

let collect_query ~loc uri =
  let rec aux acc = function
    | [] -> acc
    | (k, [ ":int" ]) :: xs -> aux (`q (k, false, `int) :: acc) xs
    | (k, [ ":int?" ]) :: xs -> aux (`q (k, true, `int) :: acc) xs
    | (k, [ ":string" ]) :: xs -> aux (`q (k, false, `string) :: acc) xs
    | (k, [ ":string?" ]) :: xs -> aux (`q (k, true, `string) :: acc) xs
    | (k, [ ":bool" ]) :: xs -> aux (`q (k, false, `bool) :: acc) xs
    | (k, [ ":bool?" ]) :: xs -> aux (`q (k, true, `bool) :: acc) xs
    | _ ->
        Location.raise_errorf ~loc
          "unsupported query parameter type, should be either :int, \
           :bool or :string"
  in
  aux [] (Uri.query uri)

let route_expand method_ ~ctxt:_ ({ txt; loc } : label loc) =
  let method_ =
    match method_ with
    | `GET -> [%expr `GET]
    | `POST -> [%expr `POST]
    | `PUT -> [%expr `PUT]
    | `DELETE -> [%expr `DELETE]
  in
  let uri = Uri.of_string txt in
  let params_rev = collect_params_rev ~loc uri in
  let query = collect_query ~loc uri in
  let handle =
    let pf, f = patt_and_expr ~loc (gen_symbol ~prefix:"f" ()) in
    let preq, req = patt_and_expr ~loc (gen_symbol ~prefix:"req" ()) in
    let pk, k = patt_and_expr ~loc (gen_symbol ~prefix:"k" ()) in
    let body = [%expr [%e f]] in
    let body =
      List.fold_left params_rev ~init:body ~f:(fun f param ->
          match param with
          | `path _ -> f
          | `param param ->
              let x =
                [%expr Dream.param [%e req] [%e estring ~loc param]]
              in
              pexp_apply ~loc f [ Labelled param, x ])
    in
    let body =
      List.fold_left query ~init:body ~f:(fun f param ->
          match param with
          | `q (param, is_opt, _) ->
              let x =
                [%expr Dream.query [%e req] [%e estring ~loc param]]
              in
              let x =
                match is_opt with
                | true -> x
                | false ->
                    [%expr
                      match [%e x] with
                      | Some x -> x
                      | None ->
                          (* TODO: better error handling *)
                          let msg =
                            Printf.sprintf "missing query parameter %s"
                              [%e estring ~loc param]
                          in
                          failwith msg]
              in
              pexp_apply ~loc f [ Labelled param, x ])
    in
    [%expr fun [%p pk] [%p pf] [%p preq] -> [%e k] [%e body] [%e req]]
  in
  let href =
    let pout, out = patt_and_expr ~loc (gen_symbol ~prefix:"out" ()) in
    let psep, sep = patt_and_expr ~loc (gen_symbol ~prefix:"_sep" ()) in
    let body = [%expr Buffer.contents [%e out]] in
    let body =
      match query with
      | [] -> body
      | q :: qs ->
          let f acc (`q (param, is_opt, _)) =
            let pvalue, value = patt_and_expr ~loc param in
            let write =
              [%expr
                Buffer.add_char [%e out] ![%e sep];
                Buffer.add_string [%e out] [%e estring ~loc param];
                [%e sep] := '&';
                Buffer.add_char [%e out] '=';
                Buffer.add_string [%e out] [%e value]]
            in
            match is_opt with
            | false ->
                [%expr
                  [%e write];
                  [%e acc]]
            | true ->
                [%expr
                  (match [%e value] with
                  | None -> ()
                  | Some [%p pvalue] -> [%e write]);
                  [%e acc]]
          in
          let body = f body q in
          List.fold_left qs ~init:body ~f
    in
    let body =
      List.fold_left params_rev ~init:body ~f:(fun acc param ->
          match param with
          | `path x ->
              [%expr
                Buffer.add_char [%e out] '/';
                Buffer.add_string [%e out] [%e estring ~loc x];
                [%e acc]]
          | `param x ->
              [%expr
                Buffer.add_char [%e out] '/';
                Buffer.add_string [%e out] [%e evar ~loc x];
                [%e acc]])
    in
    let body =
      match params_rev, query with
      | [], [] -> [%expr Fun.const "/"]
      | _ ->
          [%expr
            fun () ->
              let [%p pout] = Buffer.create 16 in
              let [%p psep] = ref '?' in
              [%e body]]
    in
    let body =
      List.fold_left params_rev ~init:body ~f:(fun body param ->
          match param with
          | `path _ -> body
          | `param x -> pexp_fun ~loc (Labelled x) None (pvar ~loc x) body)
    in
    List.fold_left query ~init:body
      ~f:(fun body (`q (param, is_opt, _ty)) ->
        let label = if is_opt then Optional param else Labelled param in
        pexp_fun ~loc label None (pvar ~loc param) body)
  in
  [%expr
    {
      Ppx_router_runtime.method_ = [%e method_];
      path = [%e estring ~loc (Uri.path uri)];
      handle = [%e handle];
    },
      [%e href]]

let method_to_string = function
  | `GET -> "GET"
  | `POST -> "POST"
  | `PUT -> "PUT"
  | `DELETE -> "DELETE"

let route_ext method_ =
  let pattern =
    let open Ast_pattern in
    single_expr_payload (estring __')
  in
  Context_free.Rule.extension
    (Extension.V3.declare
       (method_to_string method_)
       Extension.Context.expression pattern (route_expand method_))

let () =
  Driver.register_transformation
    ~rules:
      [
        route_ext `GET; route_ext `POST; route_ext `PUT; route_ext `DELETE;
      ]
    "ppx_route"
