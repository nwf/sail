(****************************************************************************)
(*     Sail                                                                 *)
(*                                                                          *)
(*  Sail and the Sail architecture models here, comprising all files and    *)
(*  directories except the ASL-derived Sail code in the aarch64 directory,  *)
(*  are subject to the BSD two-clause licence below.                        *)
(*                                                                          *)
(*  The ASL derived parts of the ARMv8.3 specification in                   *)
(*  aarch64/no_vector and aarch64/full are copyright ARM Ltd.               *)
(*                                                                          *)
(*  Copyright (c) 2013-2021                                                 *)
(*    Kathyrn Gray                                                          *)
(*    Shaked Flur                                                           *)
(*    Stephen Kell                                                          *)
(*    Gabriel Kerneis                                                       *)
(*    Robert Norton-Wright                                                  *)
(*    Christopher Pulte                                                     *)
(*    Peter Sewell                                                          *)
(*    Alasdair Armstrong                                                    *)
(*    Brian Campbell                                                        *)
(*    Thomas Bauereiss                                                      *)
(*    Anthony Fox                                                           *)
(*    Jon French                                                            *)
(*    Dominic Mulligan                                                      *)
(*    Stephen Kell                                                          *)
(*    Mark Wassell                                                          *)
(*    Alastair Reid (Arm Ltd)                                               *)
(*                                                                          *)
(*  All rights reserved.                                                    *)
(*                                                                          *)
(*  This work was partially supported by EPSRC grant EP/K008528/1 <a        *)
(*  href="http://www.cl.cam.ac.uk/users/pes20/rems">REMS: Rigorous          *)
(*  Engineering for Mainstream Systems</a>, an ARM iCASE award, EPSRC IAA   *)
(*  KTF funding, and donations from Arm.  This project has received         *)
(*  funding from the European Research Council (ERC) under the European     *)
(*  Union’s Horizon 2020 research and innovation programme (grant           *)
(*  agreement No 789108, ELVER).                                            *)
(*                                                                          *)
(*  This software was developed by SRI International and the University of  *)
(*  Cambridge Computer Laboratory (Department of Computer Science and       *)
(*  Technology) under DARPA/AFRL contracts FA8650-18-C-7809 ("CIFV")        *)
(*  and FA8750-10-C-0237 ("CTSRD").                                         *)
(*                                                                          *)
(*  SPDX-License-Identifier: BSD-2-Clause                                   *)
(****************************************************************************)

(** Compile Sail ASTs to Jib intermediate representation *)

open Anf
open Ast
open Ast_defs
open Ast_util
open Jib
open Type_check

(** This forces all integer struct fields to be represented as
   int64_t. Specifically intended for the various TLB structs in the
   ARM v8.5 spec. It is unsound in general. *)
val optimize_aarch64_fast_struct : bool ref

(** (WIP) [opt_memo_cache] will store the compiled function
   definitions in file _sbuild/ccacheDIGEST where DIGEST is the md5sum
   of the original function to be compiled. Enabled using the -memo
   flag. Uses Marshal so it's quite picky about the exact version of
   the Sail version. This cache can obviously become stale if the Sail
   changes - it'll load an old version compiled without said
   changes. *)
val opt_memo_cache : bool ref

(** {2 Jib context} *)

(** Dynamic context for compiling Sail to Jib. We need to pass a
   (global) typechecking environment given by checking the full
   AST. *)
type ctx = {
  target_name : string;
  records : (kid list * ctyp Bindings.t) Bindings.t;
  enums : IdSet.t Bindings.t;
  variants : (kid list * ctyp Bindings.t) Bindings.t;
  valspecs : (string option * ctyp list * ctyp * uannot) Bindings.t;
  quants : ctyp KBindings.t;
  local_env : Env.t;
  tc_env : Env.t;
  effect_info : Effects.side_effect_info;
  locals : (mut * ctyp) Bindings.t;
  letbinds : int list;
  letbind_ids : IdSet.t;
  no_raw : bool;
  coverage_override : bool;
  def_annot : unit def_annot option;
}

val ctx_is_extern : id -> ctx -> bool

val ctx_get_extern : id -> ctx -> string

val ctx_has_val_spec : id -> ctx -> bool

(** Create an inital Jib compilation context.

    The target is the name that would appear in a valspec extern section, i.e.

    val foo = { systemverilog: "bar", c: "baz" } = ...

    would mean "systemverilog" and "c" would be valid for_target parameters.
    If unspecified it will get the current target name from the Target module.
    If unspecified and there is no current target, it defaults to "c". *)
val initial_ctx : ?for_target:string -> Env.t -> Effects.side_effect_info -> ctx

(** {2 Compilation functions} *)

(** The Config module specifies static configuration for compiling
   Sail into Jib.  We have to provide a conversion function from Sail
   types into Jib types, as well as a function that optimizes ANF
   expressions (which can just be the identity function) *)
module type CONFIG = sig
  val convert_typ : ctx -> typ -> ctyp

  val optimize_anf : ctx -> typ aexp -> typ aexp

  (** Unroll all for loops a bounded number of times. Used for SMT
      generation. *)
  val unroll_loops : int option

  (** A call is precise if the function arguments match the function
      type exactly. Leaving functions imprecise can allow later passes
      to specialize implementations. *)
  val make_call_precise : ctx -> id -> ctyp list -> ctyp -> bool

  (** If false, will ensure that fixed size bitvectors are
      specifically less that 64-bits. If true this restriction will
      be ignored. *)
  val ignore_64 : bool

  (** If false we won't generate any V_struct values *)
  val struct_value : bool

  (** If false we won't generate any V_tuple values *)
  val tuple_value : bool

  (** Allow real literals *)
  val use_real : bool

  (** Insert branch coverage operations *)
  val branch_coverage : out_channel option

  (** If true track the location of the last exception thrown, useful
      for debugging C but we want to turn it off for SMT generation
      where we can't use strings *)
  val track_throw : bool

  val use_void : bool

  (** Convert control flow where all branches are pure into, into eager variants, i.e.

      let x = if b else y then z

      becomes

      let x = eager_if(b, y, z)

      so `y` and `z` are eagerly evaluated before the if-statement
      which just becomes like a function call. Reducing the
      control-flow like this is useful for the Sail->SV and Sail->SMT
      backends. *)
  val eager_control_flow : bool
end

module IdGraph : sig
  include Graph.S with type node = id and type node_set = IdSet.t
end

val callgraph : cdef list -> IdGraph.graph

module Make (C : CONFIG) : sig
  (** Compile a Sail definition into a Jib definition. The first two
       arguments are is the current definition number and the total
       number of definitions, and can be used to drive a progress bar
       (see Util.progress). *)
  val compile_def : int -> int -> ctx -> typed_def -> cdef list * ctx

  val compile_ast : ctx -> typed_ast -> cdef list * ctx
end

(** Adds some special functions to the environment that are used to
   convert several Sail language features, these are sail_assert,
   sail_exit, and sail_cons. *)
val add_special_functions : Env.t -> Effects.side_effect_info -> Env.t * Effects.side_effect_info
