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

(** The A-normal form (ANF) grammar

    The first step in compiling Sail into Jib IR is converting the
    Sail expression grammar into A-normal form (ANF). Essentially this
    converts expressions such as [f(g(x), h(y))] into something like:

    [let v0 = g(x) in let v1 = h(x) in f(v0, v1)]

    Essentially the arguments to every function must be trivial, and
    complex expressions must be let bound to new variables, or used in
    a block, assignment, or control flow statement (if, for, and
    while/until loops). The [aexp] datatype represents these
    expressions, while [aval] represents the trivial values.

    The convention is that the type of an aexp is given by last
    argument to a constructor. It is omitted where it is obvious - for
    example all for loops have unit as their type. If some constituent
    part of the aexp has an annotation, the it refers to the previous
    argument, so in

    [AE_let (id, typ1, _, body, typ2)]

    [typ1] is the type of the bound identifer, whereas [typ2] is the
    type of the whole let expression (and therefore also the body).
    The type is represented as a generic parameter ['a], so we can
    represent both typed and untyped ANF expressions.

    See Flanagan et al's {e The Essence of Compiling with Continuations}. *)

open Ast
open Ast_util
open Jib
open Type_check

(** Each ANF expression has an annotation which contains the location of
    the original Sail expression, it's typing environment, and the
    uannot type containing any attributes attached to the original
    expression. *)
type anf_annot = { loc : l; env : Env.t; uannot : uannot }

type 'a aexp = AE_aux of 'a aexp_aux * anf_annot

and 'a aexp_aux =
  | AE_val of 'a aval
  | AE_app of id * 'a aval list * 'a
  | AE_typ of 'a aexp * 'a
  | AE_assign of 'a alexp * 'a aexp
  | AE_let of mut * id * 'a * 'a aexp * 'a aexp * 'a
  | AE_block of 'a aexp list * 'a aexp * 'a
  | AE_return of 'a aval * 'a
  | AE_exit of 'a aval * 'a
  | AE_throw of 'a aval * 'a
  | AE_if of 'a aval * 'a aexp * 'a aexp * 'a
  | AE_field of 'a aval * id * 'a
  | AE_match of 'a aval * ('a apat * 'a aexp * 'a aexp * uannot) list * 'a
  | AE_try of 'a aexp * ('a apat * 'a aexp * 'a aexp * uannot) list * 'a
  | AE_struct_update of 'a aval * 'a aval Bindings.t * 'a
  | AE_for of id * 'a aexp * 'a aexp * 'a aexp * order * 'a aexp
  | AE_loop of loop * 'a aexp * 'a aexp
  | AE_short_circuit of sc_op * 'a aval * 'a aexp
      (** A short circuting operator (either [and] or [or]) must have
          only its first argument reduced to a trivial value in the
          ANF representation. *)

and sc_op = SC_and | SC_or

and 'a apat = AP_aux of 'a apat_aux * anf_annot

and 'a apat_aux =
  | AP_tuple of 'a apat list
  | AP_id of id * 'a
  | AP_global of id * 'a
  | AP_app of id * 'a apat * 'a
  | AP_cons of 'a apat * 'a apat
  | AP_as of 'a apat * id * 'a
  | AP_struct of (id * 'a apat) list * 'a
  | AP_nil of 'a
  | AP_wild of 'a

(** We allow ANF->ANF optimization to insert fragments of Jib IR
   directly in the ANF grammar via [AV_cval]. Such fragments
   must be side-effect free expressions. *)
and 'a aval =
  | AV_lit of lit * 'a
  | AV_id of id * 'a lvar
  | AV_abstract of id * 'a
  | AV_ref of id * 'a lvar
  | AV_tuple of 'a aval list
  | AV_list of 'a aval list * 'a
  | AV_vector of 'a aval list * 'a
  | AV_record of 'a aval Bindings.t * 'a
  | AV_cval of cval * 'a

and 'a alexp = AL_id of id * 'a | AL_addr of id * 'a | AL_field of 'a alexp * id

(** When the ANF translation has to introduce new bindings it uses a
    counter to ensure uniqueness. This function resets that counter. *)
val reset_anf_counter : unit -> unit

(** Get the location from an [aexp]'s annotation *)
val aexp_loc : 'a aexp -> Parse_ast.l

(** {2 Functions for transforming and querying ANF expressions} *)

val aval_typ : typ aval -> typ
val aexp_typ : typ aexp -> typ

(** Map over all values in an ANF expression *)
val map_aval : (anf_annot -> 'a aval -> 'a aval) -> 'a aexp -> 'a aexp

(** Map over all function calls in an ANF expression *)
val map_functions : (anf_annot -> id -> 'a aval list -> 'a -> 'a aexp_aux) -> 'a aexp -> 'a aexp

(** This function 'folds' an [aexp] applying the provided function to
    all leaf subexpressions, then applying the function to their
    containing expression, and so on recursively in a bottom-up order. *)
val fold_aexp : ('a aexp -> 'a aexp) -> 'a aexp -> 'a aexp

val aexp_bindings : 'a aexp -> IdSet.t

val is_pure_aexp : Effects.side_effect_info -> 'a aexp -> bool

val is_pure_case : Effects.side_effect_info -> 'a apat * 'a aexp * 'a aexp * uannot -> bool

(** Remove all variable shadowing in an ANF expression *)
val no_shadow : IdSet.t -> 'a aexp -> 'a aexp

val apat_globals : 'a apat -> (id * 'a) list
val apat_types : 'a apat -> 'a Bindings.t

(** Returns true if an ANF expression is dead due to flow typing
   implying it is unreachable. Note: This function calls SMT. *)
val is_dead_aexp : 'a aexp -> bool

(** {2 Compiling to ANF expressions} *)

val anf_pat : ?global:bool -> tannot pat -> typ apat

val anf : tannot exp -> typ aexp

(** {2 Pretty printing ANF expressions} *)

val pp_aval : typ aval -> PPrint.document
val pp_aexp : typ aexp -> PPrint.document
