default Order dec

$sail_internal

$include <flow.sail>

$[sv_module { stdout = true }]
val print = "print_endline" : string -> unit

union option ('a : Type) = {
  Some : 'a,
  None : unit
}

union ast = {
  HCF : unit
}

val decode : unit -> option(ast)

function decode() = Some(HCF())

val main : unit -> unit

function main() = {
  let instr = decode();
  match instr {
    Some(HCF()) => print("HCF"),
    Some(_) => print("Some(_)"),
    None() => print("None")
  }
}
