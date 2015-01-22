(* *********************************************************************)
(*                                                                     *)
(*              The Compcert verified compiler                         *)
(*                                                                     *)
(*          Xavier Leroy, INRIA Paris-Rocquencourt                     *)
(*                                                                     *)
(*  Copyright Institut National de Recherche en Informatique et en     *)
(*  Automatique.  All rights reserved.  This file is distributed       *)
(*  under the terms of the INRIA Non-Commercial License Agreement.     *)
(*                                                                     *)
(* *********************************************************************)

(* Printing PPC assembly code in asm syntax *)

open Printf
open Datatypes
open Maps
open Camlcoq
open Sections
open AST
open Memdata
open Asm

(* Recognition of target ABI and asm syntax *)

module type SYSTEM =
    sig
      val comment: string
      val constant: out_channel -> constant -> unit
      val ireg: out_channel -> ireg -> unit
      val freg: out_channel -> freg -> unit
      val creg: out_channel -> int -> unit
      val name_of_section: section_name -> string
      val print_file_line: out_channel -> string -> int -> unit
      val cfi_startproc: out_channel -> unit
      val cfi_endproc: out_channel -> unit
      val cfi_adjust: out_channel -> int32 -> unit
      val cfi_rel_offset: out_channel -> string -> int32 -> unit
      val print_prologue: out_channel -> unit
    end

let symbol oc symb =
  fprintf oc "%s" (extern_atom symb)

let symbol_offset oc (symb, ofs) =
  symbol oc symb;
  if ofs <> 0l then fprintf oc " + %ld" ofs

let symbol_fragment oc s n op =
      fprintf oc "(%a)%s" symbol_offset (s, camlint_of_coqint n) op


let int_reg_name = function
  | GPR0 -> "0"  | GPR1 -> "1"  | GPR2 -> "2"  | GPR3 -> "3"
  | GPR4 -> "4"  | GPR5 -> "5"  | GPR6 -> "6"  | GPR7 -> "7"
  | GPR8 -> "8"  | GPR9 -> "9"  | GPR10 -> "10" | GPR11 -> "11"
  | GPR12 -> "12" | GPR13 -> "13" | GPR14 -> "14" | GPR15 -> "15"
  | GPR16 -> "16" | GPR17 -> "17" | GPR18 -> "18" | GPR19 -> "19"
  | GPR20 -> "20" | GPR21 -> "21" | GPR22 -> "22" | GPR23 -> "23"
  | GPR24 -> "24" | GPR25 -> "25" | GPR26 -> "26" | GPR27 -> "27"
  | GPR28 -> "28" | GPR29 -> "29" | GPR30 -> "30" | GPR31 -> "31"

let float_reg_name = function
  | FPR0 -> "0"  | FPR1 -> "1"  | FPR2 -> "2"  | FPR3 -> "3"
  | FPR4 -> "4"  | FPR5 -> "5"  | FPR6 -> "6"  | FPR7 -> "7"
  | FPR8 -> "8"  | FPR9 -> "9"  | FPR10 -> "10" | FPR11 -> "11"
  | FPR12 -> "12" | FPR13 -> "13" | FPR14 -> "14" | FPR15 -> "15"
  | FPR16 -> "16" | FPR17 -> "17" | FPR18 -> "18" | FPR19 -> "19"
  | FPR20 -> "20" | FPR21 -> "21" | FPR22 -> "22" | FPR23 -> "23"
  | FPR24 -> "24" | FPR25 -> "25" | FPR26 -> "26" | FPR27 -> "27"
  | FPR28 -> "28" | FPR29 -> "29" | FPR30 -> "30" | FPR31 -> "31"

module Linux_System : SYSTEM =
  struct
    let comment =  "#"

    let constant oc cst =
      match cst with
      | Cint n ->
          fprintf oc "%ld" (camlint_of_coqint n)
      | Csymbol_low(s, n) ->
          symbol_fragment oc s n "@l"
      | Csymbol_high(s, n) ->
          symbol_fragment oc s n "@ha"
      | Csymbol_sda(s, n) ->
          symbol_fragment oc s n "@sda21"
            (* 32-bit relative addressing is supported by the Diab tools but not by
               GNU binutils.  In the latter case, for testing purposes, we treat
               them as absolute addressings.  The default base register being GPR0,
               this produces correct code, albeit with absolute addresses. *)
      | Csymbol_rel_low(s, n) ->
          symbol_fragment oc s n "@l"
      | Csymbol_rel_high(s, n) ->
          symbol_fragment oc s n "@ha"

    let ireg oc r =
      output_string oc (int_reg_name r)

    let freg oc r =
      output_string oc (float_reg_name r)
        
    let creg oc r = 
      fprintf oc "%d" r
 
    let name_of_section = function
      | Section_text -> ".text"
      | Section_data i ->
          if i then ".data" else "COMM"
      | Section_small_data i -> 
          if i then ".section	.sdata,\"aw\",@progbits" else "COMM"
      | Section_const i ->
          if i then ".rodata" else "COMM"
      | Section_small_const i ->
          if i then ".section	.sdata2,\"a\",@progbits" else "COMM"
      | Section_string -> ".rodata"
      | Section_literal -> ".section	.rodata.cst8,\"aM\",@progbits,8"
      | Section_jumptable -> ".text"
      | Section_user(s, wr, ex) ->
          sprintf ".section	\"%s\",\"a%s%s\",@progbits"
            s (if wr then "w" else "") (if ex then "x" else "")

    let print_file_line oc file line =
      PrintAnnot.print_file_line oc comment file line
    
    (* Emit .cfi directives *)      
    let cfi_startproc =
      if Configuration.asm_supports_cfi then
        (fun oc -> fprintf oc "	.cfi_startproc\n")
      else
        (fun _ -> ())

    let cfi_endproc =
      if Configuration.asm_supports_cfi then
        (fun oc -> fprintf oc "	.cfi_endproc\n")
      else
        (fun _ -> ())

              
    let cfi_adjust =
      if Configuration.asm_supports_cfi then
       (fun oc delta -> fprintf oc "	.cfi_adjust_cfa_offset	%ld\n" delta)
      else
        (fun _ _ -> ())
              
    let cfi_rel_offset =
      if Configuration.asm_supports_cfi then
        (fun oc reg ofs -> fprintf oc "	.cfi_rel_offset	%s, %ld\n" reg ofs)
      else
        (fun _ _ _ -> ())


    let print_prologue oc = ()
  
  end
    
module Diab_System : SYSTEM =
  struct
    let comment =  ";"
        
    let constant oc cst =
      match cst with
      | Cint n ->
          fprintf oc "%ld" (camlint_of_coqint n)
      | Csymbol_low(s, n) ->
          symbol_fragment oc s n "@l"
      | Csymbol_high(s, n) ->
          symbol_fragment oc s n "@ha"
      | Csymbol_sda(s, n) ->
          symbol_fragment oc s n "@sdarx"
      | Csymbol_rel_low(s, n) ->
          symbol_fragment oc s n "@sdax@l"
      | Csymbol_rel_high(s, n) ->
          symbol_fragment oc s n "@sdarx@ha"
 
    let ireg oc r =
      output_char oc 'r';
      output_string oc (int_reg_name r)

    let freg oc r =
      output_char oc 'f';
      output_string oc (float_reg_name r)
        
    let creg oc r =
      fprintf oc "cr%d" r
        
    let name_of_section = function
      | Section_text -> ".text"
      | Section_data i -> if i then ".data" else "COMM"
      | Section_small_data i -> if i then ".sdata" else ".sbss"
      | Section_const _ -> ".text"
      | Section_small_const _ -> ".sdata2"
      | Section_string -> ".text"
      | Section_literal -> ".text"
      | Section_jumptable -> ".text"
      | Section_user(s, wr, ex) ->
          sprintf ".section	\"%s\",,%c"
               s
            (match wr, ex with
            | true, true -> 'm'                 (* text+data *)
            | true, false -> 'd'                (* data *)
            | false, true -> 'c'                (* text *)
            | false, false -> 'r')              (* const *)

    let print_file_line oc file line =
      PrintAnnot.print_file_line_d1 oc comment file line

    (* Emit .cfi directives *)
    let cfi_startproc oc = ()

    let cfi_endproc oc = ()

    let cfi_adjust oc delta = ()

    let cfi_rel_offset oc reg ofs = ()
        
    let print_prologue oc =
      fprintf oc "	.xopt	align-fill-text=0x60000000\n";
      if !Clflags.option_g then
        fprintf oc "	.xopt	asm-debug-on\n"
  
  end

module AsmPrinter (Target : SYSTEM) =
  struct
    open Target

(* On-the-fly label renaming *)

let next_label = ref 100

let new_label() =
  let lbl = !next_label in incr next_label; lbl

let current_function_labels = (Hashtbl.create 39 : (label, int) Hashtbl.t)

let transl_label lbl =
  try
    Hashtbl.find current_function_labels lbl
  with Not_found ->
    let lbl' = new_label() in
    Hashtbl.add current_function_labels lbl lbl';
    lbl'

(* Basic printing functions *)

let coqint oc n =
  fprintf oc "%ld" (camlint_of_coqint n)

let raw_symbol oc s =
  fprintf oc "%s" s


let label oc lbl =
  fprintf oc ".L%d" lbl

let label_low oc lbl =
  fprintf oc ".L%d@l" lbl

let label_high oc lbl =
  fprintf oc ".L%d@ha" lbl


let num_crbit = function
  | CRbit_0 -> 0
  | CRbit_1 -> 1
  | CRbit_2 -> 2
  | CRbit_3 -> 3
  | CRbit_6 -> 6

let crbit oc bit =
  fprintf oc "%d" (num_crbit bit)

let ireg_or_zero oc r =
  if r = GPR0 then output_string oc "0" else ireg oc r

let preg oc = function
  | IR r -> ireg oc r
  | FR r -> freg oc r
  | _    -> assert false

let section oc sec =
  let name = name_of_section sec in
  assert (name <> "COMM");
  fprintf oc "	%s\n" name

let print_location oc loc =
  if loc <> Cutil.no_loc then print_file_line oc (fst loc) (snd loc)

(* Encoding masks for rlwinm instructions *)

let rolm_mask n =
  let mb = ref 0       (* location of last 0->1 transition *)
  and me = ref 32      (* location of last 1->0 transition *)
  and last = ref ((Int32.logand n 1l) <> 0l)  (* last bit seen *)
  and count = ref 0    (* number of transitions *)
  and mask = ref 0x8000_0000l in
  for mx = 0 to 31 do
    if Int32.logand n !mask <> 0l then
      if !last then () else (incr count; mb := mx; last := true)
    else
      if !last then (incr count; me := mx; last := false) else ();
    mask := Int32.shift_right_logical !mask 1
  done;
  if !me = 0 then me := 32;
  assert (!count = 2 || (!count = 0 && !last));
  (!mb, !me-1)

(* Handling of annotations *)

let re_file_line = Str.regexp "#line:\\(.*\\):\\([1-9][0-9]*\\)$"

let print_annot_stmt oc txt targs args =
  if Str.string_match re_file_line txt 0 then begin
    print_file_line oc (Str.matched_group 1 txt)
                       (int_of_string (Str.matched_group 2 txt))
  end else begin
    fprintf oc "%s annotation: " comment;
    PrintAnnot.print_annot_stmt preg "R1" oc txt targs args
  end

(* Determine if the displacement of a conditional branch fits the short form *)

let short_cond_branch tbl pc lbl_dest =
  match PTree.get lbl_dest tbl with
  | None -> assert false
  | Some pc_dest -> 
      let disp = pc_dest - pc in -0x2000 <= disp && disp < 0x2000

(* Printing of instructions *)

let float_literals : (int * int64) list ref = ref []
let float32_literals : (int * int32) list ref = ref []
let jumptables : (int * label list) list ref = ref []

let print_instruction oc tbl pc fallthrough = function
  | Padd(r1, r2, r3) ->
      fprintf oc "	add	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Paddc(r1, r2, r3) ->
      fprintf oc "	addc	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Padde(r1, r2, r3) ->
      fprintf oc "	adde	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Paddi(r1, r2, c) ->
      fprintf oc "	addi	%a, %a, %a\n" ireg r1 ireg_or_zero r2 constant c
  | Paddic(r1, r2, c) ->
      fprintf oc "	addic	%a, %a, %a\n" ireg r1 ireg_or_zero r2 constant c
  | Paddis(r1, r2, c) ->
      fprintf oc "	addis	%a, %a, %a\n" ireg r1 ireg_or_zero r2 constant c
  | Paddze(r1, r2) ->
      fprintf oc "	addze	%a, %a\n" ireg r1 ireg r2
  | Pallocframe(sz, ofs) ->
      assert false
  | Pand_(r1, r2, r3) ->
      fprintf oc "	and.	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Pandc(r1, r2, r3) ->
      fprintf oc "	andc	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Pandi_(r1, r2, c) ->
      fprintf oc "	andi.	%a, %a, %a\n" ireg r1 ireg r2 constant c
  | Pandis_(r1, r2, c) ->
      fprintf oc "	andis.	%a, %a, %a\n" ireg r1 ireg r2 constant c
  | Pb lbl ->
      fprintf oc "	b	%a\n" label (transl_label lbl)
  | Pbctr sg ->
      fprintf oc "	bctr\n"
  | Pbctrl sg ->
      fprintf oc "	bctrl\n"
  | Pbdnz lbl ->
      fprintf oc "	bdnz	%a\n" label (transl_label lbl)
  | Pbf(bit, lbl) ->
      if !Clflags.option_faligncondbranchs > 0 then
        fprintf oc "	.balign	%d\n" !Clflags.option_faligncondbranchs;
      if short_cond_branch tbl pc lbl then
        fprintf oc "	bf	%a, %a\n" crbit bit label (transl_label lbl)
      else begin
        let next = new_label() in
        fprintf oc "	bt	%a, %a\n" crbit bit label next;
        fprintf oc "	b	%a\n" label (transl_label lbl);
        fprintf oc "%a:\n" label next
      end
  | Pbl(s, sg) ->
      fprintf oc "	bl	%a\n" symbol s
  | Pbs(s, sg) ->
      fprintf oc "	b	%a\n" symbol s
  | Pblr ->
      fprintf oc "	blr\n"
  | Pbt(bit, lbl) ->
      if !Clflags.option_faligncondbranchs > 0 then
        fprintf oc "	.balign	%d\n" !Clflags.option_faligncondbranchs;
      if short_cond_branch tbl pc lbl then
        fprintf oc "	bt	%a, %a\n" crbit bit label (transl_label lbl)
      else begin
        let next = new_label() in
        fprintf oc "	bf	%a, %a\n" crbit bit label next;
        fprintf oc "	b	%a\n" label (transl_label lbl);
        fprintf oc "%a:\n" label next
      end
  | Pbtbl(r, tbl) ->
      let lbl = new_label() in
      fprintf oc "%s begin pseudoinstr btbl(%a)\n" comment ireg r;
      fprintf oc "%s jumptable [ " comment;
      List.iter (fun l -> fprintf oc "%a " label (transl_label l)) tbl;
      fprintf oc "]\n";
      fprintf oc "	slwi    %a, %a, 2\n" ireg GPR12 ireg r;
      fprintf oc "	addis	%a, %a, %a\n" ireg GPR12 ireg GPR12 label_high lbl;
      fprintf oc "	lwz	%a, %a(%a)\n" ireg GPR12 label_low lbl ireg GPR12;
      fprintf oc "	mtctr	%a\n" ireg GPR12;
      fprintf oc "	bctr\n";
      jumptables := (lbl, tbl) :: !jumptables;
      fprintf oc "%s end pseudoinstr btbl\n" comment
  | Pcmplw(r1, r2) ->
      fprintf oc "	cmplw	%a, %a, %a\n" creg 0 ireg r1 ireg r2
  | Pcmplwi(r1, c) ->
      fprintf oc "	cmplwi	%a, %a, %a\n" creg 0 ireg r1 constant c
  | Pcmpw(r1, r2) ->
      fprintf oc "	cmpw	%a, %a, %a\n" creg 0 ireg r1 ireg r2
  | Pcmpwi(r1, c) ->
      fprintf oc "	cmpwi	%a, %a, %a\n" creg 0 ireg r1 constant c
  | Pcntlz(r1, r2) ->
      fprintf oc "	cntlz	%a, %a\n" ireg r1 ireg r2
  | Pcreqv(c1, c2, c3) ->
      fprintf oc "	creqv	%a, %a, %a\n" crbit c1 crbit c2 crbit c3
  | Pcror(c1, c2, c3) ->
      fprintf oc "	cror	%a, %a, %a\n" crbit c1 crbit c2 crbit c3
  | Pcrxor(c1, c2, c3) ->
      fprintf oc "	crxor	%a, %a, %a\n" crbit c1 crbit c2 crbit c3
  | Pdivw(r1, r2, r3) ->
      fprintf oc "	divw	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Pdivwu(r1, r2, r3) ->
      fprintf oc "	divwu	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Peieio ->
      fprintf oc "	eieio\n"
  | Peqv(r1, r2, r3) ->
      fprintf oc "	eqv	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Pextsb(r1, r2) ->
      fprintf oc "	extsb	%a, %a\n" ireg r1 ireg r2
  | Pextsh(r1, r2) ->
      fprintf oc "	extsh	%a, %a\n" ireg r1 ireg r2
  | Pfreeframe(sz, ofs) ->
      assert false
  | Pfabs(r1, r2) | Pfabss(r1, r2) ->
      fprintf oc "	fabs	%a, %a\n" freg r1 freg r2
  | Pfadd(r1, r2, r3) ->
      fprintf oc "	fadd	%a, %a, %a\n" freg r1 freg r2 freg r3
  | Pfadds(r1, r2, r3) ->
      fprintf oc "	fadds	%a, %a, %a\n" freg r1 freg r2 freg r3
  | Pfcmpu(r1, r2) ->
      fprintf oc "	fcmpu	%a, %a, %a\n" creg 0 freg r1 freg r2
  | Pfcti(r1, r2) ->
      assert false
  | Pfctiw(r1, r2) ->
      fprintf oc "	fctiw	%a, %a\n" freg r1 freg r2
  | Pfctiwz(r1, r2) ->
      fprintf oc "	fctiwz	%a, %a\n" freg r1 freg r2
  | Pfdiv(r1, r2, r3) ->
      fprintf oc "	fdiv	%a, %a, %a\n" freg r1 freg r2 freg r3
  | Pfdivs(r1, r2, r3) ->
      fprintf oc "	fdivs	%a, %a, %a\n" freg r1 freg r2 freg r3
  | Pfmake(rd, r1, r2) ->
      assert false
  | Pfmr(r1, r2) ->
      fprintf oc "	fmr	%a, %a\n" freg r1 freg r2
  | Pfmul(r1, r2, r3) ->
      fprintf oc "	fmul	%a, %a, %a\n" freg r1 freg r2 freg r3
  | Pfmuls(r1, r2, r3) ->
      fprintf oc "	fmuls	%a, %a, %a\n" freg r1 freg r2 freg r3
  | Pfneg(r1, r2) | Pfnegs(r1, r2) ->
      fprintf oc "	fneg	%a, %a\n" freg r1 freg r2
  | Pfrsp(r1, r2) ->
      fprintf oc "	frsp	%a, %a\n" freg r1 freg r2
  | Pfxdp(r1, r2) ->
      assert false
  | Pfsub(r1, r2, r3) ->
      fprintf oc "	fsub	%a, %a, %a\n" freg r1 freg r2 freg r3
  | Pfsubs(r1, r2, r3) ->
      fprintf oc "	fsubs	%a, %a, %a\n" freg r1 freg r2 freg r3
  | Pfmadd(r1, r2, r3, r4) ->
      fprintf oc "	fmadd	%a, %a, %a, %a\n" freg r1 freg r2 freg r3 freg r4
  | Pfmsub(r1, r2, r3, r4) ->
      fprintf oc "	fmsub	%a, %a, %a, %a\n" freg r1 freg r2 freg r3 freg r4
  | Pfnmadd(r1, r2, r3, r4) ->
      fprintf oc "	fnmadd	%a, %a, %a, %a\n" freg r1 freg r2 freg r3 freg r4
  | Pfnmsub(r1, r2, r3, r4) ->
      fprintf oc "	fnmsub	%a, %a, %a, %a\n" freg r1 freg r2 freg r3 freg r4
  | Pfsqrt(r1, r2) ->
      fprintf oc "	fsqrt	%a, %a\n" freg r1 freg r2    
  | Pfrsqrte(r1, r2) ->
      fprintf oc "	frsqrte	%a, %a\n" freg r1 freg r2    
  | Pfres(r1, r2) ->
      fprintf oc "	fres	%a, %a\n" freg r1 freg r2    
  | Pfsel(r1, r2, r3, r4) ->
      fprintf oc "	fsel	%a, %a, %a, %a\n" freg r1 freg r2 freg r3 freg r4
  | Pisync ->
      fprintf oc "	isync\n"
  | Plbz(r1, c, r2) ->
      fprintf oc "	lbz	%a, %a(%a)\n" ireg r1 constant c ireg r2
  | Plbzx(r1, r2, r3) ->
      fprintf oc "	lbzx	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Plfd(r1, c, r2)  | Plfd_a(r1, c, r2) ->
      fprintf oc "	lfd	%a, %a(%a)\n" freg r1 constant c ireg r2
  | Plfdx(r1, r2, r3) | Plfdx_a(r1, r2, r3) ->
      fprintf oc "	lfdx	%a, %a, %a\n" freg r1 ireg r2 ireg r3
  | Plfs(r1, c, r2) ->
      fprintf oc "	lfs	%a, %a(%a)\n" freg r1 constant c ireg r2
  | Plfsx(r1, r2, r3) ->
      fprintf oc "	lfsx	%a, %a, %a\n" freg r1 ireg r2 ireg r3
  | Plha(r1, c, r2) ->
      fprintf oc "	lha	%a, %a(%a)\n" ireg r1 constant c ireg r2
  | Plhax(r1, r2, r3) ->
      fprintf oc "	lhax	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Plhbrx(r1, r2, r3) ->
      fprintf oc "	lhbrx	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Plhz(r1, c, r2) ->
      fprintf oc "	lhz	%a, %a(%a)\n" ireg r1 constant c ireg r2
  | Plhzx(r1, r2, r3) ->
      fprintf oc "	lhzx	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Plfi(r1, c) ->
      let lbl = new_label() in
      fprintf oc "	addis	%a, 0, %a\n" ireg GPR12 label_high lbl;
      fprintf oc "	lfd	%a, %a(%a) %s %.18g\n" freg r1 label_low lbl ireg GPR12 comment (camlfloat_of_coqfloat c);
      float_literals := (lbl, camlint64_of_coqint (Floats.Float.to_bits c)) :: !float_literals;
  | Plfis(r1, c) ->
      let lbl = new_label() in
      fprintf oc "	addis	%a, 0, %a\n" ireg GPR12 label_high lbl;
      fprintf oc "	lfs	%a, %a(%a) %s %.18g\n" freg r1 label_low lbl ireg GPR12 comment (camlfloat_of_coqfloat32 c);
      float32_literals := (lbl, camlint_of_coqint (Floats.Float32.to_bits c)) :: !float32_literals;
  | Plwarx(r1, r2, r3) ->
      fprintf oc "	lwarx	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Plwbrx(r1, r2, r3) ->
      fprintf oc "	lwbrx	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Plwz(r1, c, r2) | Plwz_a(r1, c, r2) ->
      fprintf oc "	lwz	%a, %a(%a)\n" ireg r1 constant c ireg r2
  | Plwzu(r1, c, r2) ->
      fprintf oc "	lwzu	%a, %a(%a)\n" ireg r1 constant c ireg r2
  | Plwzx(r1, r2, r3) | Plwzx_a(r1, r2, r3) ->
      fprintf oc "	lwzx	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Pmfcr(r1) ->
      fprintf oc "	mfcr	%a\n" ireg r1
  | Pmfcrbit(r1, bit) ->
      assert false
  | Pmflr(r1) ->
      fprintf oc "	mflr	%a\n" ireg r1
  | Pmr(r1, r2) ->
      fprintf oc "	mr	%a, %a\n" ireg r1 ireg r2
  | Pmtctr(r1) ->
      fprintf oc "	mtctr	%a\n" ireg r1
  | Pmtlr(r1) ->
      fprintf oc "	mtlr	%a\n" ireg r1
  | Pmulli(r1, r2, c) ->
      fprintf oc "	mulli	%a, %a, %a\n" ireg r1 ireg r2 constant c
  | Pmullw(r1, r2, r3) ->
      fprintf oc "	mullw	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Pmulhw(r1, r2, r3) ->
      fprintf oc "	mulhw	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Pmulhwu(r1, r2, r3) ->
      fprintf oc "	mulhwu	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Pnand(r1, r2, r3) ->
      fprintf oc "	nand	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Pnor(r1, r2, r3) ->
      fprintf oc "	nor	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Por(r1, r2, r3) ->
      fprintf oc "	or	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Porc(r1, r2, r3) ->
      fprintf oc "	orc	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Pori(r1, r2, c) ->
      fprintf oc "	ori	%a, %a, %a\n" ireg r1 ireg r2 constant c
  | Poris(r1, r2, c) ->
      fprintf oc "	oris	%a, %a, %a\n" ireg r1 ireg r2 constant c
  | Prlwinm(r1, r2, c1, c2) ->
      let (mb, me) = rolm_mask (camlint_of_coqint c2) in
      fprintf oc "	rlwinm	%a, %a, %ld, %d, %d %s 0x%lx\n"
                ireg r1 ireg r2 (camlint_of_coqint c1) mb me
                comment (camlint_of_coqint c2)
  | Prlwimi(r1, r2, c1, c2) ->
      let (mb, me) = rolm_mask (camlint_of_coqint c2) in
      fprintf oc "	rlwimi	%a, %a, %ld, %d, %d %s 0x%lx\n"
                ireg r1 ireg r2 (camlint_of_coqint c1) mb me
                comment (camlint_of_coqint c2)
  | Pslw(r1, r2, r3) ->
      fprintf oc "	slw	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Psraw(r1, r2, r3) ->
      fprintf oc "	sraw	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Psrawi(r1, r2, c) ->
      fprintf oc "	srawi	%a, %a, %ld\n" ireg r1 ireg r2 (camlint_of_coqint c)
  | Psrw(r1, r2, r3) ->
      fprintf oc "	srw	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Pstb(r1, c, r2) ->
      fprintf oc "	stb	%a, %a(%a)\n" ireg r1 constant c ireg r2
  | Pstbx(r1, r2, r3) ->
      fprintf oc "	stbx	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Pstfd(r1, c, r2) | Pstfd_a(r1, c, r2) ->
      fprintf oc "	stfd	%a, %a(%a)\n" freg r1 constant c ireg r2
  | Pstfdu(r1, c, r2) ->
      fprintf oc "	stfdu	%a, %a(%a)\n" freg r1 constant c ireg r2
  | Pstfdx(r1, r2, r3) | Pstfdx_a(r1, r2, r3) ->
      fprintf oc "	stfdx	%a, %a, %a\n" freg r1 ireg r2 ireg r3
  | Pstfs(r1, c, r2) ->
      fprintf oc "	stfs	%a, %a(%a)\n" freg r1 constant c ireg r2
  | Pstfsx(r1, r2, r3) ->
      fprintf oc "	stfsx	%a, %a, %a\n" freg r1 ireg r2 ireg r3
  | Psth(r1, c, r2) ->
      fprintf oc "	sth	%a, %a(%a)\n" ireg r1 constant c ireg r2
  | Psthx(r1, r2, r3) ->
      fprintf oc "	sthx	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Psthbrx(r1, r2, r3) ->
      fprintf oc "	sthbrx	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Pstw(r1, c, r2) | Pstw_a(r1, c, r2) ->
      fprintf oc "	stw	%a, %a(%a)\n" ireg r1 constant c ireg r2
  | Pstwu(r1, c, r2) ->
      fprintf oc "	stwu	%a, %a(%a)\n" ireg r1 constant c ireg r2
  | Pstwx(r1, r2, r3) | Pstwx_a(r1, r2, r3) ->
      fprintf oc "	stwx	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Pstwxu(r1, r2, r3) ->
      fprintf oc "	stwxu	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Pstwbrx(r1, r2, r3) ->
      fprintf oc "	stwbrx	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Pstwcx_(r1, r2, r3) ->
      fprintf oc "	stwcx.	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Psubfc(r1, r2, r3) ->
      fprintf oc "	subfc	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Psubfe(r1, r2, r3) ->
      fprintf oc "	subfe	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Psubfze(r1, r2) ->
      fprintf oc "	subfze	%a, %a\n" ireg r1 ireg r2
  | Psubfic(r1, r2, c) ->
      fprintf oc "	subfic	%a, %a, %a\n" ireg r1 ireg r2 constant c
  | Psync ->
      fprintf oc "	sync\n"
  | Ptrap ->
      fprintf oc "	trap\n"
  | Pxor(r1, r2, r3) ->
      fprintf oc "	xor	%a, %a, %a\n" ireg r1 ireg r2 ireg r3
  | Pxori(r1, r2, c) ->
      fprintf oc "	xori	%a, %a, %a\n" ireg r1 ireg r2 constant c
  | Pxoris(r1, r2, c) ->
      fprintf oc "	xoris	%a, %a, %a\n" ireg r1 ireg r2 constant c
  | Plabel lbl ->
      if (not fallthrough) && !Clflags.option_falignbranchtargets > 0 then
        fprintf oc "	.balign	%d\n" !Clflags.option_falignbranchtargets;
      fprintf oc "%a:\n" label (transl_label lbl)
  | Pbuiltin(ef, args, res) ->
      begin match ef with
      | EF_inline_asm txt ->
          fprintf oc "%s begin inline assembly\n" comment;
          fprintf oc "	%s\n" (extern_atom txt);
          fprintf oc "%s end inline assembly\n" comment
      | _ ->
          assert false
      end
  | Pannot(ef, args) ->
      begin match ef with
      | EF_annot(txt, targs) ->
          print_annot_stmt oc (extern_atom txt) targs args
      | _ ->
          assert false
      end
  | Pcfi_adjust n ->
      cfi_adjust oc (camlint_of_coqint n)
  | Pcfi_rel_offset n ->
      cfi_rel_offset oc "lr" (camlint_of_coqint n)

(* Determine if an instruction falls through *)

let instr_fall_through = function
  | Pb _ -> false
  | Pbctr _ -> false
  | Pbs _ -> false
  | Pblr -> false
  | _ -> true

(* Estimate the size of an Asm instruction encoding, in number of actual
   PowerPC instructions.  We can over-approximate. *)

let instr_size = function
  | Pbf(bit, lbl) -> 2
  | Pbt(bit, lbl) -> 2
  | Pbtbl(r, tbl) -> 5
  | Plfi(r1, c) -> 2
  | Plfis(r1, c) -> 2
  | Plabel lbl -> 0
  | Pbuiltin(ef, args, res) -> 0
  | Pannot(ef, args) -> 0
  | Pcfi_adjust _ | Pcfi_rel_offset _ -> 0
  | _ -> 1

(* Build a table label -> estimated position in generated code.
   Used to predict if relative conditional branches can use the short form. *)

let rec label_positions tbl pc = function
  | [] -> tbl
  | Plabel lbl :: c -> label_positions (PTree.set lbl pc tbl) pc c
  | i :: c -> label_positions tbl (pc + instr_size i) c

(* Emit a sequence of instructions *)

let rec print_instructions oc tbl pc fallthrough = function
  | [] -> ()
  | i :: c ->
      print_instruction oc tbl pc fallthrough i;
      print_instructions oc tbl (pc + instr_size i) (instr_fall_through i) c

(* Print the code for a function *)

let print_literal64 oc (lbl, n) =
  let nlo = Int64.to_int32 n
  and nhi = Int64.to_int32(Int64.shift_right_logical n 32) in
  fprintf oc "%a:	.long	0x%lx, 0x%lx\n" label lbl nhi nlo

let print_literal32 oc (lbl, n) =
  fprintf oc "%a:	.long	0x%lx\n" label lbl n

let print_jumptable oc (lbl, tbl) =
  fprintf oc "%a:" label lbl;
  List.iter
    (fun l -> fprintf oc "	.long	%a\n" label (transl_label l))
    tbl

let print_function oc name fn =
  Hashtbl.clear current_function_labels;
  float_literals := [];
  float32_literals := [];
  jumptables := [];
  let (text, lit, jmptbl) =
    match C2C.atom_sections name with
    | [t;l;j] -> (t, l, j)
    |    _    -> (Section_text, Section_literal, Section_jumptable) in
  section oc text;
  let alignment =
    match !Clflags.option_falignfunctions with Some n -> n | None -> 4 in
  fprintf oc "	.balign %d\n" alignment;
  if not (C2C.atom_is_static name) then
    fprintf oc "	.globl %a\n" symbol name;
  fprintf oc "%a:\n" symbol name;
  print_location oc (C2C.atom_location name);
  cfi_startproc oc;
  print_instructions oc (label_positions PTree.empty 0 fn.fn_code) 
                        0 true fn.fn_code;
  cfi_endproc oc;
  fprintf oc "	.type	%a, @function\n" symbol name;
  fprintf oc "	.size	%a, . - %a\n" symbol name symbol name;
  if !float_literals <> [] || !float32_literals <> [] then begin
    section oc lit;
    fprintf oc "	.balign 8\n";
    List.iter (print_literal64 oc) !float_literals;
    List.iter (print_literal32 oc) !float32_literals;
    float_literals := []; float32_literals := []
  end;
  if !jumptables <> [] then begin
    section oc jmptbl;
    fprintf oc "	.balign 4\n";
    List.iter (print_jumptable oc) !jumptables;
    jumptables := []
  end

(* Generation of whole programs *)

let print_fundef oc name defn =
  match defn with
  | Internal code ->
      print_function oc name code
  | External _ ->
      ()

let print_init oc = function
  | Init_int8 n ->
      fprintf oc "	.byte	%ld\n" (camlint_of_coqint n)
  | Init_int16 n ->
      fprintf oc "	.short	%ld\n" (camlint_of_coqint n)
  | Init_int32 n ->
      fprintf oc "	.long	%ld\n" (camlint_of_coqint n)
  | Init_int64 n ->
      let b = camlint64_of_coqint n in
      fprintf oc "	.long	0x%Lx, 0x%Lx\n"
                 (Int64.shift_right_logical b 32)
                 (Int64.logand b 0xFFFFFFFFL)
  | Init_float32 n ->
      fprintf oc "	.long	0x%lx %s %.18g\n"
                 (camlint_of_coqint (Floats.Float32.to_bits n))
                 comment (camlfloat_of_coqfloat n)
  | Init_float64 n ->
      let b = camlint64_of_coqint (Floats.Float.to_bits n) in
      fprintf oc "	.long	0x%Lx, 0x%Lx %s %.18g\n"
                 (Int64.shift_right_logical b 32)
                 (Int64.logand b 0xFFFFFFFFL)
                 comment (camlfloat_of_coqfloat n)
  | Init_space n ->
      if Z.gt n Z.zero then
        fprintf oc "	.space	%s\n" (Z.to_string n)
  | Init_addrof(symb, ofs) ->
      fprintf oc "	.long	%a\n" 
                 symbol_offset (symb, camlint_of_coqint ofs)

let print_init_data oc name id =
  if Str.string_match PrintCsyntax.re_string_literal (extern_atom name) 0
  && List.for_all (function Init_int8 _ -> true | _ -> false) id
  then
    fprintf oc "	.ascii	\"%s\"\n" (PrintCsyntax.string_of_init id)
  else
    List.iter (print_init oc) id

let print_var oc name v =
  match v.gvar_init with
  | [] -> ()
  | _  ->
      let sec =
        match C2C.atom_sections name with
        | [s] -> s
        |  _  -> Section_data true
      and align =
        match C2C.atom_alignof name with
        | Some a -> a
        | None -> 8 in (* 8-alignment is a safe default *)
      let name_sec =
        name_of_section sec in
      if name_sec <> "COMM" then begin
        fprintf oc "	%s\n" name_sec;
        fprintf oc "	.balign	%d\n" align;
        if not (C2C.atom_is_static name) then
          fprintf oc "	.globl	%a\n" symbol name;
        fprintf oc "%a:\n" symbol name;
        print_init_data oc name v.gvar_init;
        fprintf oc "	.type	%a, @object\n" symbol name;
        fprintf oc "	.size	%a, . - %a\n" symbol name symbol name
      end else begin
        let sz =
          match v.gvar_init with [Init_space sz] -> sz | _ -> assert false in
        fprintf oc "	%s	%a, %s, %d\n"
          (if C2C.atom_is_static name then ".lcomm" else ".comm")
          symbol name
          (Z.to_string sz)
          align
      end

let print_globdef oc (name, gdef) =
  match gdef with
  | Gfun f -> print_fundef oc name f
  | Gvar v -> print_var oc name v

  end

type target = Linux | Diab

let print_program oc p =
  let target = 
    (match Configuration.system with
    | "linux"  -> Linux
    | "diab"   -> Diab
    | _        -> invalid_arg ("System " ^ Configuration.system ^ " not supported")) in
  let module Target = (val (match target with
  | Linux -> (module Linux_System:SYSTEM)
  | Diab -> (module Diab_System:SYSTEM)):SYSTEM) in
  PrintAnnot.reset_filenames();
  PrintAnnot.print_version_and_options oc Target.comment;
  let module Printer = AsmPrinter(Target) in
  Target.print_prologue oc;
  List.iter (Printer.print_globdef oc) p.prog_defs;
  PrintAnnot.close_filenames()


