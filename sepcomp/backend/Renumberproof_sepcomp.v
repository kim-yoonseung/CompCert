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

(** Postorder renumbering of RTL control-flow graphs. *)

Require Import Coqlib.
Require Import Maps.
Require Import Postorder.
Require Import Events.
Require Import Globalenvs.
Require Import Smallstep.
Require Import Language.
Require Import Op.
Require Import Registers.
Require Import RTL.
Require Import Renumber.
Require Import Linkeq.
Require Import SepcompRel.
Require Import RTL_sepcomp.
Require Import sflib.

Inductive match_fundef: forall (fd fd': fundef), Prop :=
| match_fundef_transl fd fd'
    (FD: transf_fundef fd = fd'):
    match_fundef fd fd'
| match_fundef_identical fd:
    match_fundef fd fd.

Section PRESERVATION.

Variable prog: program.
Variable tprog: program.
Hypothesis TRANSF:
  @sepcomp_rel
    Language_RTL Language_RTL
    (fun p f tf => transf_function f = tf \/ f = tf)
    (fun p ef tef => ef = tef)
    (@Errors.OK _)
    prog tprog.
Let ge := Genv.globalenv prog.
Let tge := Genv.globalenv tprog.

Lemma functions_translated:
  forall v f,
  Genv.find_funct ge v = Some f ->
  exists tf, Genv.find_funct tge v = Some tf /\ (match_fundef f tf).
Proof.
  generalize (find_funct_transf_optionally _ _ TRANSF).
  intros H1 v f. specialize (H1 v f).
  revert H1. unfold ge, fundef. simpl.
  match goal with
    | [|- _ -> ?a = _ -> _] => destruct a
  end; intros H1 H2; inv H2.
  specialize (H1 eq_refl). destruct H1 as [? [? H1]].
  exists x.
  split; auto.
  destruct H1 as [[prog1 [_ H1]] | H1].
  + destruct f.
    * constructor; auto.
    * rewrite H1; apply match_fundef_identical.
  + rewrite H1; apply match_fundef_identical.
Qed.

Lemma function_ptr_translated:
  forall v f,
  Genv.find_funct_ptr ge v = Some f ->
  exists tf, Genv.find_funct_ptr tge v = Some tf /\ (match_fundef f tf).
Proof.
  generalize (find_funct_ptr_transf_optionally _ _ TRANSF).
  intros H1 v f. specialize (H1 v f).
  revert H1. unfold ge, fundef. simpl.
  match goal with
    | [|- _ -> ?a = _ -> _] => destruct a
  end; intros H1 H2; inv H2.
  specialize (H1 eq_refl). destruct H1 as [? [? H1]].
  exists x.
  split; auto.
  destruct H1 as [[prog1 [_ H1]] | H1].
  + destruct f.
    * constructor; auto.
    * rewrite H1; apply match_fundef_identical.
  + rewrite H1; apply match_fundef_identical.
Qed.

Lemma symbols_preserved:
  forall id,
  Genv.find_symbol tge id = Genv.find_symbol ge id.
Proof (find_symbol_transf_optionally _ _ TRANSF).

Lemma varinfo_preserved:
  forall b, Genv.find_var_info tge b = Genv.find_var_info ge b.
Proof (find_var_info_transf_optionally _ _ TRANSF).

Lemma sig_preserved:
  forall f, funsig (transf_fundef f) = funsig f.
Proof.
  destruct f; reflexivity.
Qed.

Lemma match_fundef_sig:
  forall f1 f2 (MATCHFD: match_fundef f1 f2), funsig f2 = funsig f1.
Proof.
  intros. inv MATCHFD; auto.
  eapply sig_preserved.
Qed.

Lemma find_function_translated:
  forall ros rs fd,
  find_function ge ros rs = Some fd ->
  exists tfd, find_function tge ros rs = Some tfd /\ (match_fundef fd tfd).
Proof.
  unfold find_function; intros. destruct ros as [r|id]. 
  eapply functions_translated; eauto.
  rewrite symbols_preserved. destruct (Genv.find_symbol ge id); try congruence.
  eapply function_ptr_translated; eauto.
Qed.

(** Effect of an injective renaming of nodes on a CFG. *)

Section RENUMBER.

Variable f: PTree.t positive.

Hypothesis f_inj: forall x1 x2 y, f!x1 = Some y -> f!x2 = Some y -> x1 = x2.

Lemma renum_cfg_nodes:
  forall c x y i,
  c!x = Some i -> f!x = Some y -> (renum_cfg f c)!y = Some(renum_instr f i).
Proof.
  set (P := fun (c c': code) =>
              forall x y i, c!x = Some i -> f!x = Some y -> c'!y = Some(renum_instr f i)).
  intros c0. change (P c0 (renum_cfg f c0)). unfold renum_cfg. 
  apply PTree_Properties.fold_rec; unfold P; intros.
  (* extensionality *)
  eapply H0; eauto. rewrite H; auto. 
  (* base *)
  rewrite PTree.gempty in H; congruence.
  (* induction *)
  rewrite PTree.gsspec in H2. unfold renum_node. destruct (peq x k). 
  inv H2. rewrite H3. apply PTree.gss. 
  destruct f!k as [y'|] eqn:?. 
  rewrite PTree.gso. eauto. red; intros; subst y'. elim n. eapply f_inj; eauto. 
  eauto. 
Qed.

End RENUMBER.

Definition pnum (f: function) := postorder (successors_map f) f.(fn_entrypoint).

Definition reach (f: function) (pc: node) := reachable (successors_map f) f.(fn_entrypoint) pc.

Lemma transf_function_at:
  forall f pc i,
  f.(fn_code)!pc = Some i ->
  reach f pc ->
  (transf_function f).(fn_code)!(renum_pc (pnum f) pc) = Some(renum_instr (pnum f) i).
Proof.
  intros. 
  destruct (postorder_correct (successors_map f) f.(fn_entrypoint)) as [A B].
  fold (pnum f) in *. 
  unfold renum_pc. destruct (pnum f)! pc as [pc'|] eqn:?.
  simpl. eapply renum_cfg_nodes; eauto.
  elim (B pc); auto. unfold successors_map. rewrite PTree.gmap1. rewrite H. simpl. congruence.
Qed.

Ltac TR_AT :=
  match goal with
  | [ A: (fn_code _)!_ = Some _ , B: reach _ _ |- _ ] =>
        generalize (transf_function_at _ _ _ A B); simpl renum_instr; intros
  end.

Lemma reach_succ:
  forall f pc i s,
  f.(fn_code)!pc = Some i -> In s (successors_instr i) ->
  reach f pc -> reach f s.
Proof.
  unfold reach; intros. econstructor; eauto. 
  unfold successors_map. rewrite PTree.gmap1. rewrite H. auto. 
Qed.
  
Inductive match_frames: RTL.stackframe -> RTL.stackframe -> Prop :=
  | match_frames_transl: forall res f sp pc rs
        (REACH: reach f pc),
      match_frames (Stackframe res f sp pc rs)
                   (Stackframe res (transf_function f) sp (renum_pc (pnum f) pc) rs)
  | match_frames_identical : forall res f sp pc rs,
      match_frames (Stackframe res f sp pc rs)
                   (Stackframe res f sp pc rs).

Inductive match_transl_states: RTL.state -> RTL.state -> Prop :=
| match_transl_regular_states: forall stk f sp pc rs m stk'
        (STACKS: list_forall2 match_frames stk stk')
        (REACH: reach f pc),
      match_transl_states (State stk f sp pc rs m)
                   (State stk' (transf_function f) sp (renum_pc (pnum f) pc) rs m)
| match_transl_callstates: forall stk f f' args m stk'
        (FD: match_fundef f f')
        (STACKS: list_forall2 match_frames stk stk'),
      match_transl_states (Callstate stk f args m)
                   (Callstate stk' f' args m)
| match_transl_returnstates: forall stk v m stk'
        (STACKS: list_forall2 match_frames stk stk'),
      match_transl_states (Returnstate stk v m)
                   (Returnstate stk' v m).

Inductive match_identical_states: RTL.state -> RTL.state -> Prop :=
| match_identical_regular_states: forall stk f sp pc rs m stk'
        (STACKS: list_forall2 match_frames stk stk'),
      match_identical_states (State stk f sp pc rs m)
                   (State stk' f sp pc rs m).

Inductive match_states: RTL.state -> RTL.state -> Prop :=
| match_states_transl: forall st1 st2
                              (MSTATE: match_transl_states st1 st2),
                         match_states st1 st2
| match_states_identical: forall st1 st2
                              (MSTATE: match_identical_states st1 st2),
                         match_states st1 st2.

Lemma step_simulation_transl:
  forall S1 t S2, RTL.step ge S1 t S2 ->
  forall S1', match_transl_states S1 S1' ->
  exists S2', RTL.step tge S1' t S2' /\ match_states S2 S2'.
Proof.
  induction 1; intros S1' MS; inv MS; try TR_AT.
(* nop *)
  econstructor; split. eapply exec_Inop; eauto. 
  constructor; auto. constructor; eauto. eapply reach_succ; eauto. simpl; auto. 
(* op *)
  econstructor; split.
  eapply exec_Iop; eauto.
  instantiate (1 := v). rewrite <- H0. apply eval_operation_preserved. exact symbols_preserved. 
  constructor; auto. constructor; auto. eapply reach_succ; eauto. simpl; auto.
(* load *)
  econstructor; split.
  assert (eval_addressing tge sp addr rs ## args = Some a).
  rewrite <- H0. apply eval_addressing_preserved. exact symbols_preserved. 
  eapply exec_Iload; eauto.
  constructor; auto. constructor; auto. eapply reach_succ; eauto. simpl; auto.
(* store *)
  econstructor; split.
  assert (eval_addressing tge sp addr rs ## args = Some a).
  rewrite <- H0. apply eval_addressing_preserved. exact symbols_preserved. 
  eapply exec_Istore; eauto.
  constructor; auto. constructor; auto. eapply reach_succ; eauto. simpl; auto.
(* call *)
  exploit find_function_translated; eauto.
  intros Htfd. destruct Htfd as [tfd [findtfd matchtfd]].
  econstructor; split.
  eapply exec_Icall with (fd := tfd); eauto.
  inv matchtfd; auto.
    apply sig_preserved.
  constructor; auto. constructor; auto. constructor; auto. constructor; auto. eapply reach_succ; eauto. simpl; auto.
(* tailcall *)
  exploit find_function_translated; eauto.
  intros Htfd. destruct Htfd as [tfd [findtfd matchtfd]].
  econstructor; split.
  eapply exec_Itailcall with (fd := tfd); eauto.
  inv matchtfd; auto.
    apply sig_preserved.
  constructor. auto.
  constructor; auto.
(* builtin *)
  econstructor; split.
  eapply exec_Ibuiltin; eauto.
    eapply external_call_symbols_preserved; eauto.
    exact symbols_preserved. exact varinfo_preserved.
  constructor; auto. constructor; auto. eapply reach_succ; eauto. simpl; auto.
(* cond *)
  econstructor; split.
  eapply exec_Icond; eauto. 
  replace (if b then renum_pc (pnum f) ifso else renum_pc (pnum f) ifnot)
     with (renum_pc (pnum f) (if b then ifso else ifnot)).
  constructor; auto. constructor; auto. eapply reach_succ; eauto. simpl. destruct b; auto. 
  destruct b; auto.
(* jumptbl *)
  econstructor; split.
  eapply exec_Ijumptable; eauto. rewrite list_nth_z_map. rewrite H1. simpl; eauto. 
  constructor; auto. constructor; auto. eapply reach_succ; eauto. simpl. eapply list_nth_z_in; eauto. 
(* return *)
  econstructor; split.
  eapply exec_Ireturn; eauto. 
  constructor.
  constructor; auto.
(* internal function *)
  inv FD.
  (* call translated *)
  simpl. econstructor; split.
  eapply exec_function_internal; eauto. 
  constructor. constructor; auto. unfold reach. constructor.
  (* call identical *)
  simpl. econstructor; split.
  eapply exec_function_internal; eauto.
  apply match_states_identical. constructor; auto.
(* external function *)
  assert (f' = AST.External ef); subst.
  { inv FD; auto. }
  econstructor; split.
  eapply exec_function_external; eauto.
    eapply external_call_symbols_preserved; eauto.
    exact symbols_preserved. exact varinfo_preserved.
  constructor. constructor; auto.
(* return *)
  inv STACKS. inv H1.
  (* transl *)
  econstructor; split. 
  eapply exec_return; eauto. 
  constructor. constructor; auto.
  (* identical *)
  econstructor; split. 
  eapply exec_return; eauto.
  apply match_states_identical.
  constructor; auto.
Qed.

Lemma step_simulation_identical:
  forall S1 t S2, RTL.step ge S1 t S2 ->
  forall S1' (MS: match_identical_states S1 S1'),
  exists S2', RTL.step tge S1' t S2' /\ match_states S2 S2'.
Proof.
  intros. destruct (is_normal S1) eqn:NORMAL1.
  { (* is_normal *)
    destruct S1; try by inv NORMAL1.
    exploit is_normal_step; eauto. intro. des. subst.
    inv MS.
    exploit is_normal_identical;
      try apply symbols_preserved;
      try apply varinfo_preserved;
      eauto.
    intro. des.
    eexists. split. eauto.
    apply match_states_identical. econs; eauto.
  }
  inv MS. unfold is_normal in NORMAL1.
  destruct (fn_code f) ! pc as [[]|] eqn:OPCODE; try by inv NORMAL1; inv H; clarify.
  - (* Icall *)
    inv H; clarify.
    exploit find_function_translated; eauto.
    intro. des.
    eexists. split.
    { eapply exec_Icall; eauto.
      eapply match_fundef_sig. eauto.
    }
    econs. econs; eauto.
    constructor; eauto.
    eapply match_frames_identical; eauto.
  - (* Itailcall *)
    inv H; clarify.
    exploit find_function_translated; eauto.
    intro. des.
    eexists. split.
    { eapply exec_Itailcall; eauto.
      eapply match_fundef_sig. eauto.
    }
    econs. econs; eauto.
  - (* Ireturn *)
    inv H; clarify.
    eexists. split.
    { eapply exec_Ireturn; eauto. }
    econs. econs; eauto.
Qed.

Lemma step_simulation:
  forall S1 t S2, RTL.step ge S1 t S2 ->
  forall S1' (MS: match_states S1 S1'),
  exists S2', RTL.step tge S1' t S2' /\ match_states S2 S2'.
Proof.
  intros. inv MS.
  - eapply step_simulation_transl; eauto.
  - eapply step_simulation_identical; eauto.
Qed.
  

Lemma transf_initial_states:
  forall S1, RTL.initial_state prog S1 ->
  exists S2, RTL.initial_state tprog S2 /\ match_states S1 S2.
Proof.
  intros. inv H.
  exploit function_ptr_translated; eauto.
  intros Htf. destruct Htf as [tf [findtf matchtf]].
  econstructor; split.
  econstructor. 
    eapply (init_mem_transf_optionally _ _ TRANSF); eauto. 
    replace (AST.prog_main tprog) with (AST.prog_main prog).
    rewrite symbols_preserved. eauto.
    inv TRANSF. auto.
    eauto.    
    inv matchtf; auto.
    rewrite <- H3; apply sig_preserved.
  constructor; auto. constructor; auto. constructor.
Qed.

Lemma transf_final_states:
  forall S1 S2 r, match_states S1 S2 -> RTL.final_state S1 r -> RTL.final_state S2 r.
Proof.
  intros. inv H0. inv H; inv MSTATE. inv STACKS. constructor.
Qed.

Theorem transf_program_correct:
  forward_simulation (RTL.semantics prog) (RTL.semantics tprog).
Proof.
  eapply forward_simulation_step.
  eexact symbols_preserved.
  eexact transf_initial_states.
  eexact transf_final_states.
  exact step_simulation. 
Qed.

End PRESERVATION.



 

  

