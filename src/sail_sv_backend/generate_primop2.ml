(**************************************************************************)
(*  Sail to verilog                                                       *)
(*                                                                        *)
(*  Copyright (c) 2023                                                    *)
(*    Alasdair Armstrong                                                  *)
(*                                                                        *)
(*  All rights reserved.                                                  *)
(*                                                                        *)
(*  Redistribution and use in source and binary forms, with or without    *)
(*  modification, are permitted provided that the following conditions    *)
(*  are met:                                                              *)
(*  1. Redistributions of source code must retain the above copyright     *)
(*     notice, this list of conditions and the following disclaimer.      *)
(*  2. Redistributions in binary form must reproduce the above copyright  *)
(*     notice, this list of conditions and the following disclaimer in    *)
(*     the documentation and/or other materials provided with the         *)
(*     distribution.                                                      *)
(*                                                                        *)
(*  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS''    *)
(*  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED     *)
(*  TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A       *)
(*  PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR   *)
(*  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,          *)
(*  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT      *)
(*  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF      *)
(*  USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND   *)
(*  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,    *)
(*  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT    *)
(*  OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF    *)
(*  SUCH DAMAGE.                                                          *)
(**************************************************************************)

open Libsail

open Ast_util
open Jib
open Jib_util
open Printf
open Sv_ir

module StringSet = Set.Make (String)

let nf s = s
let pf fmt = sprintf fmt

let sail_bits width =
  let index_top = Generate_primop.required_width (Big_int.of_int (width - 1)) in
  [
    nf "typedef struct packed {";
    pf "    logic [%d:0] size;" index_top;
    pf "    logic [%d:0] bits;" (width - 1);
    nf "} sail_bits;";
    "";
    pf "localparam SAIL_BITS_WIDTH = %d;" width;
    pf "localparam SAIL_INDEX_WIDTH = %d;" (index_top + 1);
    "";
    pf "function automatic logic [%d:0] sail_bits_size(sail_bits bv); return bv.size; endfunction" index_top;
    pf "function automatic logic [%d:0] sail_bits_value(sail_bits bv); return bv.bits; endfunction" (width - 1);
  ]

let sail_int width = [pf "typedef logic [%d:0] sail_int;" (width - 1)]

let output_primop buf lines =
  List.iter
    (fun line ->
      Buffer.add_string buf line;
      Buffer.add_char buf '\n'
    )
    lines;
  Buffer.add_char buf '\n'

let generated_library_defs = ref (StringSet.empty, [])

let register_library_def name def =
  let names, _ = !generated_library_defs in
  if StringSet.mem name names then name
  else (
    let source = def () in
    let names, defs = !generated_library_defs in
    generated_library_defs := (StringSet.add name names, source :: defs);
    name
  )

let get_generated_library_defs () = List.rev (snd !generated_library_defs)

let primop_name s = Jib_util.name (mk_id s)

let print_fbits width =
  let name = sprintf "sail_print_fixed_bits_%d" width in
  register_library_def name (fun () ->
      let b = primop_name "b" in
      let s = primop_name "s" in
      let in_str = primop_name "in_str" in
      let out_str = primop_name "out_str" in
      let always_comb =
        (* If the width is a multiple of four, format as hexadecimal.
           We take care to ensure the formatting is identical to other
           Sail backends. *)
        let zeros = Jib_util.name (mk_id "zeros") in
        let bstr = Jib_util.name (mk_id "bstr") in
        if width mod 4 = 0 then (
          let zeros_init = String.make (width / 4) '0' in
          [
            SVS_var (zeros, CT_string, None);
            SVS_var (bstr, CT_string, None);
            svs_raw "bstr.hextoa(b)" ~inputs:[b] ~outputs:[bstr];
            svs_raw (sprintf "zeros = \"%s\"" zeros_init) ~outputs:[zeros];
            svs_raw
              (sprintf
                 "out_str = {in_str, s, $sformatf(\"0x%%s\", zeros.substr(0, %d - bstr.len()), bstr.toupper()), \
                  \"\\n\"}"
                 ((width / 4) - 1)
              )
              ~inputs:[in_str; s; zeros; bstr] ~outputs:[out_str];
            SVS_assign (SVP_id Jib_util.return, Unit);
          ]
          |> List.map mk_statement
        )
        else (
          let zeros_init = String.make width '0' in
          [
            SVS_var (zeros, CT_string, None);
            SVS_var (bstr, CT_string, None);
            svs_raw "bstr.bintoa(b)" ~inputs:[b] ~outputs:[bstr];
            svs_raw (sprintf "zeros = \"%s\"" zeros_init) ~outputs:[zeros];
            svs_raw
              (sprintf "out_str = {in_str, s, $sformatf(\"0b%%s\", zeros.substr(0, %d - bstr.len())), bstr, \"\\n\"}"
                 (width - 1)
              )
              ~inputs:[in_str; s; bstr] ~outputs:[out_str];
            SVS_assign (SVP_id Jib_util.return, Unit);
          ]
          |> List.map mk_statement
        )
      in
      SVD_module
        {
          name = SVN_string name;
          input_ports = [mk_port s CT_string; mk_port b (CT_fbits width); mk_port in_str CT_string];
          output_ports = [mk_port Jib_util.return CT_unit; mk_port out_str CT_string];
          defs = [SVD_always_comb (mk_statement (SVS_block always_comb))];
        }
  )

let print_int () =
  let name = "sail_print_int" in
  register_library_def name (fun () ->
      let i = primop_name "i" in
      let s = primop_name "s" in
      let in_str = primop_name "in_str" in
      let out_str = primop_name "out_str" in
      let always_comb =
        svs_raw "out_str = {in_str, s, $sformatf(\"%0d\", signed'(i)), \"\\n\"}" ~inputs:[in_str; s; i]
          ~outputs:[out_str]
      in
      SVD_module
        {
          name = SVN_string name;
          input_ports = [mk_port s CT_string; mk_port i CT_lint; mk_port in_str CT_string];
          output_ports = [mk_port Jib_util.return CT_unit; mk_port out_str CT_string];
          defs = [SVD_always_comb (mk_statement always_comb)];
        }
  )

let binary_module l gen =
  Some
    (fun args ret_ctyp ->
      match (args, ret_ctyp) with
      | [v1; v2], ret_ctyp -> gen v1 v2 ret_ctyp
      | _ -> Reporting.unreachable l __POS__ "Incorrect arity given to binary module generator"
    )

let ternary_module l gen =
  Some
    (fun args ret_ctyp ->
      match (args, ret_ctyp) with
      | [v1; v2; v3], ret_ctyp -> gen v1 v2 v3 ret_ctyp
      | _ -> Reporting.unreachable l __POS__ "Incorrect arity given to binary module generator"
    )

let generate_module ~at:l = function
  | "print_bits" ->
      ternary_module l (fun _ v2 _ _ ->
          match cval_ctyp v2 with
          | CT_fbits width -> print_fbits width
          | _ -> Reporting.unreachable l __POS__ "Invalid types given to print_bits generator"
      )
  | "print_int" ->
      ternary_module l (fun _ v2 _ _ ->
          match cval_ctyp v2 with
          | CT_lint -> print_int ()
          | ctyp ->
              Reporting.unreachable l __POS__ ("Invalid types given to print_int generator: " ^ string_of_ctyp ctyp)
      )
  | _ -> None

let basic_defs bv_width int_width =
  let buf = Buffer.create 4096 in
  output_primop buf (sail_bits bv_width);
  output_primop buf (sail_int int_width);
  Buffer.contents buf