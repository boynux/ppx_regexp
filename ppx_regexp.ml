(* Copyright (C) 2017  Petter A. Urkedal <paurkedal@gmail.com>
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version, with the OCaml static compilation exception.
 *
 * This library is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
 * License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this library.  If not, see <http://www.gnu.org/licenses/>.
 *)

open Migrate_parsetree
open Ast_402
let ocaml_version = Versions.ocaml_402

open Ast_mapper
open Ast_helper
open Asttypes
open Parsetree
open Longident

let error ~loc msg = raise (Location.Error (Location.error ~loc msg))

let warn ~loc msg e =
  let e_msg = Exp.constant (Const_string (msg, None)) in
  let structure = {pstr_desc = Pstr_eval (e_msg, []); pstr_loc = loc} in
  Exp.attr e ({txt = "ocaml.ppwarning"; loc}, PStr [structure])

let dyn_bindings = ref []
let clear_bindings () = dyn_bindings := []
let add_binding binding = dyn_bindings := binding :: !dyn_bindings
let get_bindings () = !dyn_bindings

let fresh_var =
  let c = ref 0 in
  fun () -> incr c; Printf.sprintf "_ppx_regexp_%d" !c

let rec is_zero p k =
  (match p.[k] with
   | '0' -> is_zero p (k + 1)
   | '1'..'9' -> false
   | _ -> true)

let rec must_match p i =
  let l = String.length p in
  if i = l then true else
  if p.[i] = '?' || p.[i] = '*' then false else
  if p.[i] = '{' then
    let j = String.index_from p (i + 1) '}' in
    not (is_zero p (i + 1)) && must_match p (j + 1)
  else
    true

let extract_bindings ~loc p =
  let l = String.length p in
  let buf = Buffer.create l in
  let
    rec parse_normal nG stack bs i =
      if i = l then
        if stack = [] then (bs, nG) else
        error ~loc "Unmatched start of group."
      else begin
        Buffer.add_char buf p.[i];
        (match p.[i] with
         | '('  -> parse_bgroup nG stack bs (i + 1)
         | ')'  -> parse_egroup nG stack bs (i + 1)
         | '\\' -> parse_escape nG stack bs (i + 1)
         | _ ->    parse_normal nG stack bs (i + 1))
      end
    and parse_escape nG stack bs i =
      if i = l then (bs, nG) else begin
        Buffer.add_char buf p.[i];
        parse_normal nG stack bs (i + 1)
      end
    and parse_bgroup nG stack bs i =
      if i + 2 >= l || p.[i] <> '?' || p.[i + 1] <> '<' then
        parse_normal (nG + 1) ((None, nG, bs) :: stack) [] i
      else
        let j = String.index_from p (i + 2) '>' in
        let varG = String.sub p (i + 2) (j - i - 2) in
        parse_normal (nG + 1) ((Some varG, nG, bs) :: stack) [] (j + 1)
    and parse_egroup nG stack bs i =
      let bs, bs', stack' =
        (match stack with
         | [] -> error ~loc "Unmached end of group."
         | ((Some varG, iG, bs') :: stack') ->
            let bs = (varG, iG, true) :: bs in
            (bs, bs', stack')
         | ((None, _, bs') :: stack') ->
            (bs, bs', stack'))
      in
      let bs =
        if must_match p i then bs else
        List.map (fun (varG, iG, _) -> (varG, iG, false)) bs
      in
      parse_normal nG stack' (List.rev_append bs bs') i
  in
  let bs, nG = parse_normal 0 [] [] 0 in
  (Buffer.contents buf, bs, nG)

let transform_cases ~loc e cases =
  let aux case =
    if case.pc_guard <> None then
      error ~loc "Guards are not implemented for match%pcre." else
    (match case.pc_lhs with
     | {ppat_desc = Ppat_constant (Const_string (re_src,_)); ppat_loc = loc} ->
        let re_str, bs, nG = extract_bindings ~loc re_src in
        (try ignore (Re_pcre.regexp re_str) with
         | Re_perl.Not_supported -> error ~loc "Unsupported regular expression."
         | Re_perl.Parse_error -> error ~loc "Invalid regular expression.");
        (Exp.constant (Const_string (re_str, None)), nG, bs, case.pc_rhs)
     | {ppat_desc = Ppat_any} ->
        error ~loc "Universal wildcard must be the last pattern."
     | {ppat_loc = loc} ->
        error ~loc "Regular expression pattern should be a string.")
  in
  let cases, default_rhs =
    (match List.rev cases with
     | {pc_lhs = {ppat_desc = Ppat_any}; pc_rhs} :: cases ->
        (cases, pc_rhs)
     | cases ->
        let open Lexing in
        let pos = loc.Location.loc_start in
        let e0 = Exp.constant (Const_string (pos.pos_fname, None)) in
        let e1 = Exp.constant (Const_int pos.pos_lnum) in
        let e2 = Exp.constant (Const_int (pos.pos_cnum - pos.pos_bol)) in
        let e = [%expr raise (Match_failure ([%e e0], [%e e1], [%e e2]))] in
        (cases, warn ~loc "A universal case is recommended for %pcre." e))
  in
  let cases = List.rev_map aux cases in
  let res = Exp.array (List.map (fun (re, _, _, _) -> re) cases) in
  let comp = [%expr
    let a = Array.map (fun s -> Re.mark (Re_pcre.re s)) [%e res] in
    let marks = Array.map fst a in
    let re = Re.compile (Re.alt (Array.to_list (Array.map snd a))) in
    (re, marks)
  ] in
  let var = fresh_var () in
  add_binding (Vb.mk (Pat.var {txt = var; loc}) comp);
  let e_comp = Exp.ident {txt = Lident var; loc} in

  let rec wrap_groups rhs offG = function
   | [] -> rhs
   | (varG, iG, mustG) :: bs ->
      let eG =
        [%expr Re.Group.get _g [%e Exp.constant (Const_int (offG + iG + 1))]]
      in
      let eG =
        if mustG then eG else
        [%expr try Some [%e eG] with Not_found -> None]
      in
      [%expr
        let [%p Pat.var {txt = varG; loc}] = [%e eG] in
        [%e wrap_groups rhs offG bs]]
  in
  let rec handle_cases i offG = function
   | [] -> [%expr assert false]
   | (_, nG, bs, rhs) :: cases ->
      let e_i = Exp.constant (Const_int i) in
      [%expr
        if Re.Mark.test _g (snd [%e e_comp]).([%e e_i]) then
          [%e wrap_groups rhs offG bs]
        else
          [%e handle_cases (i + 1) (offG + nG) cases]]
  in
  [%expr
    (match Re.exec_opt (fst [%e e_comp]) [%e e] with
     | None -> [%e default_rhs]
     | Some _g -> [%e handle_cases 0 0 cases])]

let rewrite_expr mapper e_ext =
  (match e_ext.pexp_desc with
   | Pexp_extension ({txt = "pcre"}, PStr [{pstr_desc = Pstr_eval (e, _)}]) ->
      let loc = e.pexp_loc in
      (match e.pexp_desc with
       | Pexp_match (e, cases) ->
          transform_cases ~loc e cases
       | Pexp_function (cases) ->
          [%expr fun _s -> [%e transform_cases ~loc [%expr _s] cases]]
       | _ ->
          error ~loc "[%pcre] only applies to match an function.")
   | _ -> default_mapper.expr mapper e_ext)

let rewrite_structure mapper sis =
  let sis' =
    default_mapper.structure {default_mapper with expr = rewrite_expr} sis
  in
  (match get_bindings () |> List.rev with
   | [] -> sis'
   | bindings ->
      clear_bindings ();
      let si' = {
        pstr_desc = Pstr_value (Nonrecursive, bindings);
        pstr_loc = Location.none;
      } in
      si' :: sis')

let () = Driver.register ~name:"ppx_regexp" ocaml_version
  (fun _config _cookies -> {default_mapper with structure = rewrite_structure})
