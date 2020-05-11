Require Import Koika.Frontend.
Require Import Coq.Lists.List.

Require Import Koika.Std.
Require Import DynamicIsolation.RVEncoding.
Require Import DynamicIsolation.Scoreboard.
Require Import DynamicIsolation.Multiplier.

Require Import DynamicIsolation.External.
Require Import DynamicIsolation.Lift.
Require Import DynamicIsolation.Tactics.
Require Import DynamicIsolation.Interfaces.

(* Heavily inspired by http://csg.csail.mit.edu/6.175/labs/project-part1.html *)

Definition post_t := unit.
Definition var_t := string.
Definition fn_name_t := string.


Module CacheTypes.
  Import Common.
  Import External.

  Inductive ind_cache_type :=
  | CacheType_Imem
  | CacheType_Dmem
  .

  Definition cache_mem_req :=
    {| struct_name := "cache_mem_req";
       struct_fields := [("core_id" , bits_t 1);
                         ("cache_type", enum_t cache_type);
                         ("addr"    , addr_t);
                         ("MSI_state"   , enum_t MSI)
                        ]
    |}.

  Definition cache_mem_resp :=
    {| struct_name := "cache_mem_resp";
       struct_fields := [("core_id"   , bits_t 1);
                         ("cache_type", enum_t cache_type);
                         ("addr"      , addr_t);
                         ("MSI_state" , enum_t MSI);
                         ("data"      , maybe (data_t))
                        ] |}.

  Module FifoCacheMemReq <: Fifo.
    Definition T:= struct_t cache_mem_req.
  End FifoCacheMemReq.
  Module CacheMemReq := Fifo1 FifoCacheMemReq.

  Module FifoCacheMemResp <: Fifo.
    Definition T:= struct_t cache_mem_resp.
  End FifoCacheMemResp.
  Module CacheMemResp := Fifo1 FifoCacheMemResp.

  Definition cache_mem_msg_tag :=
    {| enum_name := "cache_mem_msg_tag";
       enum_members := vect_of_list ["Req"; "Resp"];
       enum_bitpatterns := vect_of_list [Ob~0; Ob~1] |}.

  (* NOTE: This should be a union type if one existed. What is the best way to encode this? *)
  Definition cache_mem_msg :=
    {| struct_name := "cache_mem_msg";
       struct_fields := [("type", enum_t cache_mem_msg_tag );
                         ("req" , struct_t cache_mem_req);
                         ("resp" , struct_t cache_mem_resp)
                        ] |}.

  (* TODO: figure out syntax to write as a function of log size *)
  Definition getTag {reg_t}: UInternalFunction reg_t empty_ext_fn_t :=
    {{ fun getTag (addr: bits_t 32) : cache_tag_t =>
         addr[|5`d14|:+18]
    }}.

  Definition getIndex {reg_t}: UInternalFunction reg_t empty_ext_fn_t :=
    {{ fun getIndex (addr: bits_t 32) : cache_index_t =>
         addr[|5`d2|:+12]
    }}.

  Definition dummy_mem_req : struct_t mem_req := value_of_bits (Bits.zero).
  Definition dummy_mem_resp : struct_t mem_resp := value_of_bits (Bits.zero).

End CacheTypes.

Module MessageFifo1.
  Import CacheTypes.

  (* A message FIFO has two enqueue methods (enq_resp and enq_req), and behaves such that a request
   * never blocks a response.
   *)
  Inductive reg_t :=
  | reqQueue (state: CacheMemReq.reg_t)
  | respQueue (state: CacheMemResp.reg_t).

  Definition R r :=
    match r with
    | reqQueue s => CacheMemReq.R s
    | respQueue s => CacheMemResp.R s
    end.

  Definition r idx : R idx :=
    match idx with
    | reqQueue s => CacheMemReq.r s
    | respQueue s => CacheMemResp.r s
    end.

  Definition enq_resp : UInternalFunction reg_t empty_ext_fn_t :=
    {{ fun enq_resp (resp: struct_t cache_mem_resp) : bits_t 0 =>
         respQueue.(CacheMemResp.enq)(resp)
    }}.

  Definition enq_req : UInternalFunction reg_t empty_ext_fn_t :=
    {{ fun enq_req (req: struct_t cache_mem_req) : bits_t 0 =>
         reqQueue.(CacheMemReq.enq)(req)
    }}.

  Definition has_resp : UInternalFunction reg_t empty_ext_fn_t :=
    {{ fun has_resp () : bits_t 1 =>
         respQueue.(CacheMemResp.can_deq)()
    }}.

  Definition has_req : UInternalFunction reg_t empty_ext_fn_t :=
    {{ fun has_req () : bits_t 1 =>
         reqQueue.(CacheMemReq.can_deq)()
    }}.

  Definition not_empty : UInternalFunction reg_t empty_ext_fn_t :=
    {{ fun not_empty () : bits_t 1 =>
         has_resp() || has_req()
    }}.

  (* TODO: ugly; peek returns a maybe type *)
  Definition peek : UInternalFunction reg_t empty_ext_fn_t :=
    {{ fun peek () : maybe (struct_t cache_mem_msg) =>
         if has_resp() then
           let resp_opt := respQueue.(CacheMemResp.peek)() in
           let msg := struct cache_mem_msg {| type := enum cache_mem_msg_tag {| Resp |};
                                              resp := get(resp_opt, data)
                                           |} in
           {valid (struct_t cache_mem_msg)}(msg)
         else if has_req() then
           let req_opt := reqQueue.(CacheMemReq.peek)() in
           let msg := struct cache_mem_msg {| type := enum cache_mem_msg_tag {| Req |};
                                              resp := get(req_opt, data)
                                           |} in
           {valid (struct_t cache_mem_msg)}(msg)
         else
           {invalid (struct_t cache_mem_msg)}()
    }}.

  Definition deq : UInternalFunction reg_t empty_ext_fn_t :=
    {{ fun deq () : struct_t cache_mem_msg =>
       guard (not_empty());
       if has_resp() then
           let resp_opt := respQueue.(CacheMemResp.deq)() in
           struct cache_mem_msg {| type := enum cache_mem_msg_tag {| Resp |};
                                   resp := resp_opt
                                |}
       else
           let req_opt := reqQueue.(CacheMemReq.deq)() in
           struct cache_mem_msg {| type := enum cache_mem_msg_tag {| Req |};
                                   req := req_opt
                                |}
   }}.

  Instance FiniteType_reg_t : FiniteType reg_t := _.

  (* TODO: Test this. *)
End MessageFifo1.

Module MessageRouter.
  Inductive internal_reg_t :=
  | routerTieBreaker (* To implement round robin fairness *)
  .

  Definition R_internal (idx: internal_reg_t) : type :=
    match idx with
    | routerTieBreaker => bits_t 2
    end.

  Definition r_internal (idx: internal_reg_t) : R_internal idx :=
    match idx with
    | routerTieBreaker => Bits.zero
    end.

  Inductive reg_t : Type :=
  | FromCore0I (state: MessageFifo1.reg_t)
  | FromCore0D (state: MessageFifo1.reg_t)
  | FromCore1I (state: MessageFifo1.reg_t)
  | FromCore1D (state: MessageFifo1.reg_t)
  | ToCore0I (state: MessageFifo1.reg_t)
  | ToCore0D (state: MessageFifo1.reg_t)
  | ToCore1I (state: MessageFifo1.reg_t)
  | ToCore1D (state: MessageFifo1.reg_t)
  | ToProto (state: MessageFifo1.reg_t)
  | FromProto (state: MessageFifo1.reg_t)
  | internal (state: internal_reg_t)
  .

  Definition R (idx: reg_t) : type :=
    match idx with
    | FromCore0I st => MessageFifo1.R st
    | FromCore0D st => MessageFifo1.R st
    | FromCore1I st => MessageFifo1.R st
    | FromCore1D st => MessageFifo1.R st
    | ToCore0I st => MessageFifo1.R st
    | ToCore0D st => MessageFifo1.R st
    | ToCore1I st => MessageFifo1.R st
    | ToCore1D st => MessageFifo1.R st
    | ToProto st => MessageFifo1.R st
    | FromProto st => MessageFifo1.R st
    | internal st => R_internal st
    end.

  Notation "'__internal__' instance " :=
    (fun reg => internal ((instance) reg)) (in custom koika at level 1, instance constr at level 99).
  Notation "'(' instance ').(' method ')' args" :=
    (USugar (UCallModule instance _ method args))
      (in custom koika at level 1, method constr, args custom koika_args at level 99).

  Import CacheTypes.
  Import External.

  Definition Sigma := empty_Sigma.
  Definition ext_fn_t := empty_ext_fn_t.
  Definition rule := rule R Sigma.

  (* ===================== Message routing rules ============================== *)
  Definition memToCore : uaction reg_t empty_ext_fn_t :=
    {{ let msg := FromProto.(MessageFifo1.deq)() in
       if (get(msg, type) == enum cache_mem_msg_tag {| Req |}) then
         let req := get(msg, req) in
         if (get(req, core_id) == Ob~0) then
           if (get(req, cache_type) == enum cache_type {| imem |}) then
             ToCore0I.(MessageFifo1.enq_req)(req)
           else
             ToCore0D.(MessageFifo1.enq_req)(req)
         else
           if (get(req, cache_type) == enum cache_type {| imem |}) then
             ToCore1I.(MessageFifo1.enq_req)(req)
           else
             ToCore1D.(MessageFifo1.enq_req)(req)
       else (* Resp *)
         let resp := get(msg, resp) in
         if (get(resp, core_id) == Ob~0) then
           if (get(resp, cache_type) == enum cache_type {| imem |}) then
             ToCore0I.(MessageFifo1.enq_resp)(resp)
           else
             ToCore0D.(MessageFifo1.enq_resp)(resp)
         else
           if (get(resp, cache_type) == enum cache_type {| imem |}) then
             ToCore1I.(MessageFifo1.enq_resp)(resp)
           else
             ToCore1D.(MessageFifo1.enq_resp)(resp)
    }}.

  Definition getResp : UInternalFunction reg_t empty_ext_fn_t :=
    {{ fun getResp (tiebreaker : bits_t 2) : maybe (struct_t cache_mem_msg) =>
           match tiebreaker with
           | #Ob~0~0 =>
               if (FromCore0I.(MessageFifo1.has_resp)()) then
                 {valid (struct_t cache_mem_msg)}(FromCore0I.(MessageFifo1.deq)())
               else
                 {invalid (struct_t cache_mem_msg)}()
           | #Ob~0~1 =>
               if (FromCore0D.(MessageFifo1.has_resp)()) then
                 {valid (struct_t cache_mem_msg)}(FromCore0D.(MessageFifo1.deq)())
               else
                 {invalid (struct_t cache_mem_msg)}()
           | #Ob~1~0 =>
               if (FromCore1I.(MessageFifo1.has_resp)()) then
                 {valid (struct_t cache_mem_msg)}(FromCore1I.(MessageFifo1.deq)())
               else
                 {invalid (struct_t cache_mem_msg)}()
           | #Ob~1~1 =>
               if (FromCore1D.(MessageFifo1.has_resp)()) then
                 {valid (struct_t cache_mem_msg)}(FromCore1D.(MessageFifo1.deq)())
               else
                 {invalid (struct_t cache_mem_msg)}()
           return default : {invalid (struct_t cache_mem_msg)}()
           end
    }}.

  Definition getReq : UInternalFunction reg_t empty_ext_fn_t :=
    {{ fun getReq (tiebreaker : bits_t 2) : maybe (struct_t cache_mem_msg) =>
           match tiebreaker with
           | #Ob~0~0 =>
               if (!FromCore0I.(MessageFifo1.has_resp)() &&
                    FromCore0I.(MessageFifo1.has_req)()) then
                 {valid (struct_t cache_mem_msg)}(FromCore0I.(MessageFifo1.deq)())
               else
                 {invalid (struct_t cache_mem_msg)}()
           | #Ob~0~1 =>
               if (!FromCore0D.(MessageFifo1.has_resp)() &&
                    FromCore0D.(MessageFifo1.has_req)()) then
                 {valid (struct_t cache_mem_msg)}(FromCore0D.(MessageFifo1.deq)())
               else
                 {invalid (struct_t cache_mem_msg)}()
           | #Ob~1~0 =>
               if (!FromCore1I.(MessageFifo1.has_resp)() &&
                    FromCore1I.(MessageFifo1.has_req)()) then
                 {valid (struct_t cache_mem_msg)}(FromCore1I.(MessageFifo1.deq)())
               else
                 {invalid (struct_t cache_mem_msg)}()
           | #Ob~1~1 =>
               if (!FromCore1D.(MessageFifo1.has_resp)() &&
                    FromCore1D.(MessageFifo1.has_req)()) then
                 {valid (struct_t cache_mem_msg)}(FromCore1D.(MessageFifo1.deq)())
               else
                 {invalid (struct_t cache_mem_msg)}()
           return default : {invalid (struct_t cache_mem_msg)}()
           end
    }}.

  (* TODO: very ugly... *)
  (* ======= Search for responses, starting with tiebreaker ====== *)
  Definition searchResponses : UInternalFunction reg_t empty_ext_fn_t :=
    {{ fun searchResponses (tiebreaker : bits_t 2) : maybe (struct_t cache_mem_msg) =>
         let foundMsg := Ob~0 in
         let msg := {invalid (struct_t cache_mem_msg)}() in
         (when (!foundMsg) do (
           let curResp := getResp (tiebreaker) in
            when (get(curResp, valid)) do (
              set foundMsg := Ob~1;
              set msg := {valid (struct_t cache_mem_msg)} (get(curResp, data));
              write0(internal routerTieBreaker, tiebreaker + |2`d1|)
            )
         ));
         (when (!foundMsg) do (
            let curResp := getResp (tiebreaker+|2`d1|) in
            when (get(curResp, valid)) do (
              set foundMsg := Ob~1;
              set msg := {valid (struct_t cache_mem_msg)} (get(curResp, data));
              write0(internal routerTieBreaker, tiebreaker + |2`d2|)
            )
          ));
         (when (!foundMsg) do (
            let curResp := getResp (tiebreaker+|2`d2|) in
            when (get(curResp, valid)) do (
              set foundMsg := Ob~1;
              set msg := {valid (struct_t cache_mem_msg)} (get(curResp, data));
              write0(internal routerTieBreaker, tiebreaker + |2`d3|)
            )
          ));
         (when (!foundMsg) do (
            let curResp := getResp (tiebreaker+|2`d3|) in
            when (get(curResp, valid)) do (
              set foundMsg := Ob~1;
              set msg := {valid (struct_t cache_mem_msg)} (get(curResp, data));
              write0(internal routerTieBreaker, tiebreaker + |2`d4|)
            )
          ));
         msg
     }}.

  (* ======= Search for responses, starting with tiebreaker ====== *)

  (* TODO: This is not isolation friendly right now; should do it round robin style *)
  Definition searchRequests : UInternalFunction reg_t empty_ext_fn_t :=
    {{ fun searchRequests (tiebreaker : bits_t 2) : maybe (struct_t cache_mem_msg) =>
         let foundMsg := Ob~0 in
         let msg := {invalid (struct_t cache_mem_msg)}() in
         (when (!foundMsg) do (
           let curReq := getReq (tiebreaker) in
            when (get(curReq, valid)) do (
              set foundMsg := Ob~1;
              set msg := curReq;
              write0(internal routerTieBreaker, tiebreaker + |2`d1|)
            )
          ));
         (when (!foundMsg) do (
           let curReq := getReq (tiebreaker+|2`d1|) in
           when (get(curReq, valid)) do (
             set foundMsg := Ob~1;
             set msg := curReq;
             write0(internal routerTieBreaker, tiebreaker + |2`d2|)
           )
         ));
         (when (!foundMsg) do (
           let curReq := getReq (tiebreaker+|2`d2|) in
           when (get(curReq, valid)) do (
             set foundMsg := Ob~1;
             set msg := curReq;
             write0(internal routerTieBreaker, tiebreaker + |2`d3|)
           )
         ));
         (when (!foundMsg) do (
           let curReq := getReq (tiebreaker+|2`d3|) in
           when (get(curReq, valid)) do (
             set foundMsg := Ob~1;
             set msg := curReq;
             write0(internal routerTieBreaker, tiebreaker + |2`d4|)
           )
         ));
         msg
     }}.

  Definition coreToMem : uaction reg_t empty_ext_fn_t :=
    {{ let tiebreaker := read0(internal routerTieBreaker) in
       (* Search for requests, starting with tieBreaker *)
       let msg_opt := searchResponses (tiebreaker) in
       if (get(msg_opt, valid)) then
         (* enqueue *)
         let msg := get(msg_opt,data) in
         ToProto.(MessageFifo1.enq_resp)(get(msg,resp))
       else
       (* Search for responses, starting with tiebreaker *)
         let msg_opt := searchRequests (tiebreaker) in
         if (get(msg_opt,valid)) then
           let msg := get(msg_opt, data) in
           ToProto.(MessageFifo1.enq_req)(get(msg,req))
         else
           write0(internal routerTieBreaker, tiebreaker + |2`d1|)
    }}.

  Inductive rule_name_t :=
  | Rl_MemToCore
  | Rl_CoreToMem
  .

  Definition tc_memToCore := tc_rule R Sigma memToCore <: rule.
  Definition tc_coreToMem := tc_rule R Sigma coreToMem <: rule.

  Definition rules (rl: rule_name_t) : rule :=
    match rl with
    | Rl_MemToCore => tc_memToCore
    | Rl_CoreToMem => tc_coreToMem
    end.

  Definition schedule : Syntax.scheduler pos_t rule_name_t :=
    Rl_MemToCore |> Rl_CoreToMem |> done.

End MessageRouter.

Module Type CacheParams.
  Parameter _core_id : Common.ind_core_id.
  Parameter _cache_type : CacheTypes.ind_cache_type.
End CacheParams.

Module Cache (Params: CacheParams).
  Import CacheTypes.
  Import Common.
  Import External.

  Definition core_id : core_id_t :=
    match Params._core_id with
    | CoreId0 => Ob~0
    | CoreId1 => Ob~1
    end.

  Definition cache_type : enum_t cache_type :=
    match Params._cache_type with
    | CacheType_Imem => Ob~0
    | CacheType_Dmem => Ob~1
    end.

  Definition external_memory : External.cache:=
    match Params._cache_type with
    | CacheType_Imem => External.imem
    | CacheType_Dmem => External.dmem
    end.

  (* Hard-coded for now: direct-mapped cache: #sets = #blocks; word-addressable *)

  Definition mshr_tag :=
    {| enum_name := "mshr_tag";
       enum_members := vect_of_list ["Ready"; "SendFillReq"; "WaitFillResp"];
       enum_bitpatterns := vect_of_list [Ob~0~0; Ob~0~1; Ob~1~0]
    |}.

  (* TODO *)
  Definition MSHR_t :=
    {| struct_name := "MSHR";
       struct_fields := [("mshr_tag", enum_t mshr_tag);
                         ("req", struct_t mem_req)
                        ] |}.

  Inductive internal_reg_t :=
  | downgradeState
  | requestsQ (state: MemReq.reg_t)
  | responsesQ (state: MemResp.reg_t)
  | MSHR
  .

  Instance FiniteType_internal_reg_t : FiniteType internal_reg_t := _.

  Definition R_internal (idx: internal_reg_t) : type :=
    match idx with
    | downgradeState => bits_t 1
    | requestsQ st => MemReq.R st
    | responsesQ st => MemResp.R st
    | mshr => struct_t MSHR_t
    end.

  Definition r_internal (idx: internal_reg_t) : R_internal idx :=
    match idx with
    | downgradeState => Ob~0
    | requestsQ st => MemReq.r st
    | responsesQ st => MemResp.r st
    | mshr => value_of_bits (Bits.zero)
    end.


  Inductive reg_t :=
  | fromMem (state: MessageFifo1.reg_t)
  | toMem (state: MessageFifo1.reg_t)
  | internal (state: internal_reg_t)
  .

  Definition R (idx: reg_t) : type :=
    match idx with
    | fromMem st => MessageFifo1.R st
    | toMem st => MessageFifo1.R st
    | internal st => R_internal st
    end.

  Notation "'__internal__' instance " :=
    (fun reg => internal ((instance) reg)) (in custom koika at level 1, instance constr at level 99).
  Notation "'(' instance ').(' method ')' args" :=
    (USugar (UCallModule instance _ method args))
      (in custom koika at level 1, method constr, args custom koika_args at level 99).

  Definition Sigma := External.Sigma.
  Definition ext_fn_t := External.ext_fn_t.

  (* Ready -> SendFillReq;
     SendFillReq -> WaitFillResp;
     WaitFillResp -> Ready
  *)

  (* Definition downgrade : uaction reg_t empty_ext_fn_t. Admitted. *)

  (* TODO: move to Std *)
  Section Maybe.
    Context (tau: type).

    Definition fromMaybe {reg_t fn}: UInternalFunction reg_t fn :=
      {{ fun fromMaybe (default: tau) (val: maybe tau) : tau =>
           if get(val, valid) then get(val, data)
           else default
      }}.
  End Maybe.

  Definition MMIO_UART_ADDRESS := Ob~0~1~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0.
  Definition MMIO_LED_ADDRESS  := Ob~0~1~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~1~0~0.

  Definition memoryBus (m: External.cache) : UInternalFunction reg_t ext_fn_t :=
    {{ fun memoryBus (get_ready: bits_t 1) (put_valid: bits_t 1) (put_request: struct_t ext_cache_mem_req)
         : struct_t cache_mem_output =>
         `match m with
          | imem => {{ extcall (ext_cache imem) (struct cache_mem_input {|
                        get_ready := get_ready;
                        put_valid := put_valid;
                        put_request := put_request |}) }}
          | dmem    =>
                   {{ extcall (ext_cache dmem) (struct cache_mem_input {|
                        get_ready := get_ready;
                        put_valid := put_valid;
                        put_request := put_request |}) }}
          end
         `
   }}.

  (* If Store: do nothing in response *)
  (* If Load: send response *)
  Definition hit (mem: External.cache): UInternalFunction reg_t ext_fn_t :=
    {{ fun hit (req: struct_t mem_req) (row: struct_t cache_row) (write_on_load: bits_t 1): enum_t mshr_tag =>
         let new_state := enum mshr_tag {| Ready |} in
         (
         if (get(req, byte_en) == Ob~0~0~0~0) then
           (__internal__ responsesQ).(MemResp.enq)(
             struct mem_resp {| addr := get(req, addr);
                                data := get(row,data);
                                byte_en := get(req, byte_en)
                             |});
             if (write_on_load) then
               let cache_req := struct ext_cache_mem_req
                                      {| byte_en := Ob~1~1~1~1;
                                         tag := getTag(get(req,addr));
                                         index := getIndex(get(req,addr));
                                         data := get(row,data);
                                         MSI := {valid (enum_t MSI)}(get(row,flag))
                                      |} in
               ignore({memoryBus mem}(Ob~1, Ob~1, cache_req))
             else pass
         else (* TODO: commit data *)
           if (get(row,flag) == enum MSI {| M |}) then
             let cache_req := struct ext_cache_mem_req
                                    {| byte_en := get(req,byte_en);
                                       tag := getTag(get(req,addr));
                                       index := getIndex(get(req,addr));
                                       data := get(req,data);
                                       MSI := {valid (enum_t MSI)}(enum MSI {| M |})
                                    |} in
             ignore({memoryBus mem}(Ob~1, Ob~1, cache_req));
             (__internal__ responsesQ).(MemResp.enq)(
               struct mem_resp {| addr := get(req, addr);
                                  data := |32`d0|;
                                  byte_en := get(req, byte_en)
                               |})
           else
             set new_state := enum mshr_tag {| SendFillReq |}
         );
         new_state
    }}.

  Definition dummy_ext_cache_mem_req : struct_t ext_cache_mem_req := value_of_bits (Bits.zero).

  Definition downgrade (mem: External.cache): uaction reg_t ext_fn_t :=
    {{
        if (fromMem.(MessageFifo1.not_empty)() &&
            !fromMem.(MessageFifo1.has_resp)()) then
          write0(internal downgradeState, Ob~1);
          let req := get(fromMem.(MessageFifo1.deq)(), req) in
          let index := getIndex(get(req,addr)) in
          let tag := getTag(get(req,addr)) in
          let cache_req := struct ext_cache_mem_req {| byte_en := Ob~0~0~0~0;
                                                       tag := tag;
                                                       index := index;
                                                       data := |32`d0|;
                                                       MSI := {invalid (enum_t MSI)}() |} in
          guard (!toMem.(MessageFifo1.has_resp)());
          let cache_output := {memoryBus mem}(Ob~1, Ob~1, cache_req) in
          guard ((get(cache_output, get_valid)));
          let row := get(get(cache_output, get_response),row) in
          if (get(row,tag) == tag &&
              ((get(req, MSI_state) == enum MSI {| I |} && get(row, flag) != enum MSI {| I |}) ||
               (get(req, MSI_state) == enum MSI {| S |} && get(row, flag) == enum MSI {| M |}))) then
            let data_opt := (if get(row,flag) == enum MSI {| M |}
                             then {valid data_t}(get(row,data))
                             else {invalid data_t}()) in
            toMem.(MessageFifo1.enq_resp)(struct cache_mem_resp {| core_id := (#core_id);
                                                                   cache_type := (`UConst (cache_type)`);
                                                                   addr := tag ++ index ++ (Ob~0~0);
                                                                   MSI_state := get(req, MSI_state);
                                                                   data := data_opt
                                                                |});
            let cache_req := struct ext_cache_mem_req {| byte_en := |4`d0|;
                                                         tag := tag;
                                                         index := index;
                                                         data := |32`d0|;
                                                         MSI := {valid (enum_t MSI)}(get(req, MSI_state))
                                                      |} in
           ignore({memoryBus mem}(Ob~1, Ob~1, cache_req))
          else pass
        else
          write0(internal downgradeState, Ob~0)
    }}.


  (* TOOD: for now, just assume miss and skip cache and forward to memory *)
  Definition process_request (mem: External.cache): uaction reg_t ext_fn_t :=
    {{
        let mshr := read0(internal MSHR) in
        let downgrade_state := read1(internal downgradeState) in
        guard((get(mshr,mshr_tag) == enum mshr_tag {| Ready |}) && !downgrade_state);
        let req := (__internal__ requestsQ).(MemReq.deq)() in
        let addr := get(req,addr) in
        let tag := getTag(addr) in
        let index := getIndex(addr) in
        (* No offset because single element cache oops *)
        let cache_req := struct ext_cache_mem_req {| byte_en := Ob~0~0~0~0;
                                                     tag := tag;
                                                     index := index;
                                                     data := get(req,data);
                                                     MSI := {invalid (enum_t MSI)}()
                                                  |} in
        guard((__internal__ responsesQ).(MemResp.can_enq)());
        guard(!toMem.(MessageFifo1.has_resp)());
        let cache_output := {memoryBus mem}(Ob~1, Ob~1, cache_req) in
        guard ((get(cache_output, get_valid)));
        let row := get(get(cache_output, get_response), row) in
        let inCache := ((get(row,tag) == tag) && (get(row,flag) != enum MSI {| I |} )) in
        if (inCache) then
          let newMSHR := {hit mem}(req, row, Ob~0) in
          write0(internal MSHR, struct MSHR_t {| mshr_tag := newMSHR;
                                                 req := req
                                              |})
          (* miss *)
        else (
          (when (get(row,flag) != enum MSI {| I |}) do ((* tags unequal; need to downgrade *)
            let data_opt := (if get(row,flag) == enum MSI {| M |}
                             then {valid data_t}(get(row,data))
                             else {invalid data_t}()) in
            toMem.(MessageFifo1.enq_resp)(struct cache_mem_resp {| core_id := (#core_id);
                                                                   cache_type := (`UConst (cache_type)`);
                                                                   addr := addr; (* CHECK *)
                                                                   MSI_state := enum MSI {| I |};
                                                                   data := data_opt |});
            let cache_req := struct ext_cache_mem_req {| byte_en := |4`d0|;
                                                         tag := |18`d0|;
                                                         index := index;
                                                         data := |32`d0|;
                                                         MSI := {valid (enum_t MSI)}(enum MSI {| I |}) |} in
            ignore({memoryBus mem}(Ob~1, Ob~1, cache_req))
          ));
          write0(internal MSHR, struct MSHR_t {| mshr_tag := enum mshr_tag {| SendFillReq |};
                                                 req := req
                                              |})
        )
    }}.


  Definition byte_en_to_msi_state : UInternalFunction reg_t empty_ext_fn_t :=
    {{ fun byte_en_to_msi_state (byte_en: bits_t 4) : enum_t MSI =>
         match byte_en with
         | #Ob~0~0~0~0 => enum MSI {| S |}
         return default : enum MSI {| M |}
         end
    }}.

  Definition SendFillReq : uaction reg_t ext_fn_t :=
    {{
        let mshr := read0(internal MSHR) in
        let downgrade_state := read1(internal downgradeState) in
        guard(get(mshr,mshr_tag) == enum mshr_tag {| SendFillReq |} && !downgrade_state);
        let mshr_req := get(mshr,req) in
        toMem.(MessageFifo1.enq_req)(
                  struct cache_mem_req {| core_id := (#core_id);
                                          cache_type := (`UConst (cache_type)`);
                                          addr := get(mshr_req, addr);
                                          MSI_state := (match get(mshr_req,byte_en) with
                                                        | #Ob~0~0~0~0 => enum MSI {| S |}
                                                        return default : enum MSI {| M |}
                                                        end)
                                       |});
        write0(internal MSHR, struct MSHR_t {| mshr_tag := enum mshr_tag {| WaitFillResp |};
                                               req := mshr_req
                                            |})
    }}.

  Definition WaitFillResp (mem: External.cache): uaction reg_t ext_fn_t :=
    {{
        let mshr := read0(internal MSHR) in
        let downgrade_state := read1(internal downgradeState) in
        guard(get(mshr,mshr_tag) == enum mshr_tag {| WaitFillResp |}
              && !downgrade_state
              && fromMem.(MessageFifo1.has_resp)());
        let resp := get(fromMem.(MessageFifo1.deq)(),resp) in

        let req := get(mshr, req) in
        let row := struct cache_row {| tag := getTag(get(req, addr));
                                       data := {fromMaybe data_t}(|32`d0|, get(resp,data));
                                       flag := get(resp, MSI_state)
                                    |} in
        ignore({hit mem}(req, row, Ob~1));
        (* write to Mem *)
        write0(internal MSHR, struct MSHR_t {| mshr_tag := enum mshr_tag {| Ready |};
                                               req := (`UConst dummy_mem_req`)
                                            |})
    }}.

  Definition can_send_req : UInternalFunction reg_t empty_ext_fn_t :=
    {{ fun can_send_req () : bits_t 1 =>
         let mshr := read0(internal MSHR) in
         get(mshr,mshr_tag) == enum mshr_tag {| Ready |} &&
         (__internal__ requestsQ).(MemReq.can_enq)()
    }}.

  Definition req: UInternalFunction reg_t empty_ext_fn_t :=
    {{ fun req (r: struct_t mem_req) : bits_t 0 =>
         let mshr := read0(internal MSHR) in
         guard(get(mshr,mshr_tag) == enum mshr_tag {| Ready |});
         (__internal__ requestsQ).(MemReq.enq)(r)
    }}.

  Definition can_recv_resp: UInternalFunction reg_t empty_ext_fn_t :=
    {{ fun can_recv_resp () : bits_t 1 =>
         (__internal__ responsesQ).(MemResp.can_deq)()
    }}.

  Definition resp: UInternalFunction reg_t empty_ext_fn_t :=
    {{ fun resp () : struct_t mem_resp =>
         (__internal__ responsesQ).(MemResp.deq)()
    }}.

  Inductive rule_name_t :=
  | Rl_Downgrade
  | Rl_ProcessRequest
  | Rl_SendFillReq
  | Rl_WaitFillResp
  .

  Definition rule := rule R Sigma.

  (* NOTE: type-checking with unbound memory doesn't fail fast *)
  Definition tc_downgrade_imem := tc_rule R Sigma (downgrade External.imem) <: rule.
  Definition tc_downgrade_dmem := tc_rule R Sigma (downgrade External.dmem) <: rule.

  Definition tc_processRequest_imem := tc_rule R Sigma (process_request External.imem) <: rule.
  Definition tc_processRequest_dmem := tc_rule R Sigma (process_request External.dmem) <: rule.
  Definition tc_sendFillReq := tc_rule R Sigma (SendFillReq) <: rule.
  Definition tc_waitFillResp_imem := tc_rule R Sigma (WaitFillResp External.imem) <: rule.
  Definition tc_waitFillResp_dmem := tc_rule R Sigma (WaitFillResp External.dmem) <: rule.

  Definition rules (rl: rule_name_t) : rule :=
    match rl with
    | Rl_Downgrade =>
        match Params._cache_type with
        | CacheType_Imem => tc_downgrade_imem
        | CacheType_Dmem => tc_downgrade_dmem
        end
    | Rl_ProcessRequest =>
        match Params._cache_type with
        | CacheType_Imem => tc_processRequest_imem
        | CacheType_Dmem => tc_processRequest_dmem
        end
    | Rl_SendFillReq => tc_sendFillReq
    | Rl_WaitFillResp =>
        match Params._cache_type with
        | CacheType_Imem => tc_waitFillResp_imem
        | CacheType_Dmem => tc_waitFillResp_dmem
        end
    end.

  Definition schedule : Syntax.scheduler pos_t rule_name_t :=
    Rl_Downgrade |> Rl_ProcessRequest |> Rl_SendFillReq |> Rl_WaitFillResp |> done.

End Cache.

Module ProtocolProcessor.
  Import Common.
  Import CacheTypes.
  Import External.

  Definition USHR_state :=
    {| enum_name := "USHR_state";
       enum_members := vect_of_list ["Ready"; "Downgrading"; "Confirming"];
       enum_bitpatterns := vect_of_list [Ob~0~0; Ob~0~1; Ob~1~0]
    |}.

  Definition USHR :=
    {| struct_name := "USHR";
       struct_fields := [("state", enum_t USHR_state);
                         ("req", struct_t cache_mem_req)]
    |}.

  Definition num_sets : nat := Nat.shiftl 1 External.log_num_sets.

  Inductive internal_reg_t :=
  | ushr
  | downgrade_tracker
  | bypass
  .

  Instance FiniteType_internal_reg_t : FiniteType internal_reg_t := _.

  Definition R_internal (reg: internal_reg_t) : type :=
    match reg with
    | ushr => struct_t USHR
    | downgrade_tracker => bits_t 4
    | bypass => maybe (data_t)
    end.

  Definition r_internal (reg: internal_reg_t) : R_internal reg :=
    match reg with
    | ushr => value_of_bits (Bits.zero)
    | downgrade_tracker => Bits.zero
    | bypass => value_of_bits (Bits.zero)
    end.

  (* TODO: Should be a DDR3_Req or similar, and should parameterise based on DDR3AddrSize/DataSize *)
  Inductive reg_t :=
  | FromRouter (state: MessageFifo1.reg_t)
  | ToRouter (state: MessageFifo1.reg_t)
  | ToMem (state: MemReq.reg_t)
  | FromMem (state: MemResp.reg_t)
  | internal (state: internal_reg_t)
  .

  Definition R (idx: reg_t) : type :=
    match idx with
    | FromRouter st => MessageFifo1.R st
    | ToRouter st => MessageFifo1.R st
    | ToMem st => MemReq.R st
    | FromMem st => MemResp.R st
    | internal st => R_internal st
    end.

  Instance FiniteType_reg_t : FiniteType reg_t := _.

  Definition Sigma := Sigma.
  Definition ext_fn_t := ext_fn_t.

  (* For now: we assume everything is always invalid because the caches don't actually exist.  *)
  Definition receive_responses : uaction reg_t ext_fn_t :=
    {{
        guard(FromRouter.(MessageFifo1.has_resp)());
        let respFromCore := get(FromRouter.(MessageFifo1.deq)(), resp) in
        let data_opt := get(respFromCore, data) in
        let resp_addr := get(respFromCore,addr) in
        (
        if (get(data_opt,valid)) then
          ToMem.(MemReq.enq)(struct mem_req {| byte_en := Ob~1~1~1~1;
                                               addr := resp_addr;
                                               data := get(data_opt, data)
                                            |});
          let ushr := read0(internal ushr) in
          if (get(ushr,state) == enum USHR_state {| Confirming |} ||
              get(ushr,state) == enum USHR_state {| Downgrading|}) then
            let req := get(ushr,req) in
            let req_addr := get(req,addr) in
            if (getTag(req_addr) == getTag(resp_addr) &&
                getIndex(req_addr) == getIndex(resp_addr)) then
              write0(internal bypass, {valid (data_t)}(get(data_opt,data)))
            else pass
          else pass
        else pass
        );
        let input := struct bookkeeping_input
                            {| idx := getIndex(resp_addr);
                               book := {valid (struct_t Bookkeeping_row)}(
                                           struct Bookkeeping_row {| state := get(respFromCore, MSI_state);
                                                                     tag := getTag(resp_addr)
                                                                  |});
                               core_id := get(respFromCore,core_id);
                               cache_type := get(respFromCore, cache_type)
                           |} in
        ignore(extcall ext_ppp_bookkeeping (input))
        (* TODO: update bookkeeping row/directory *)
    }}.

  Definition get_state : UInternalFunction reg_t ext_fn_t :=
    {{ fun get_state (core_id: bits_t 1) (cache_type: enum_t cache_type) (index: cache_index_t) (tag: cache_tag_t)
         : enum_t MSI =>
         let input := struct bookkeeping_input {| idx := index;
                                                  book := {invalid (struct_t Bookkeeping_row)}();
                                                  core_id := core_id;
                                                  cache_type := cache_type
                                               |} in
         let row_opt := extcall ext_ppp_bookkeeping (input) in
         if (get(row_opt,valid)) then
           let row := get(row_opt,data) in
           if (get(row,tag) == tag) then
             get(row,state)
           else
             enum MSI {| I |}
         else
           fail@(enum_t MSI)
     }}.

  (* Check dmem *)
  Definition has_line : UInternalFunction reg_t ext_fn_t :=
    {{ fun has_line (index: cache_index_t) (tag: cache_tag_t) (core_id: bits_t 1): bits_t 1 =>
         get_state(core_id, enum cache_type {| dmem|}, index, tag) == enum MSI {| M |}
    }}.

  Definition cache_encoding : UInternalFunction reg_t ext_fn_t :=
    {{ fun cache_encoding (core_id: bits_t 1) (cache_ty: enum_t cache_type) : bits_t 2 =>
           core_id ++ (cache_ty == enum cache_type {| dmem |})
    }}.

  Definition compute_downgrade_tracker : UInternalFunction reg_t ext_fn_t :=
    {{ fun compute_downgrade_tracker (index: cache_index_t) (tag: cache_tag_t) : bits_t 4 =>
         let core0_imem := get_state(Ob~0, enum cache_type {| imem |}, index, tag) in
         let core0_dmem := get_state(Ob~0, enum cache_type {| dmem |}, index, tag) in
         let core1_imem := get_state(Ob~1, enum cache_type {| imem |}, index, tag) in
         let core1_dmem := get_state(Ob~1, enum cache_type {| dmem |}, index, tag) in
         (core1_dmem != enum MSI {| I |}) ++
         (core1_imem != enum MSI {| I |}) ++
         (core0_dmem != enum MSI {| I |}) ++
         (core0_imem != enum MSI {| I |})
    }}.

  Definition set_invalid_at_cache : UInternalFunction reg_t ext_fn_t :=
    {{ fun set_invalid_at_cache (tracker: bits_t 4) (core_id: bits_t 1) (cache_ty: enum_t cache_type) : bits_t 4 =>
       (!(Ob~0~0~0~1 << cache_encoding (core_id, cache_ty))) && tracker
    }}.


  Definition do_downgrade_from_tracker : UInternalFunction reg_t ext_fn_t :=
    {{ fun do_downgrade_from_tracker (addr: addr_t) (tracker: bits_t 4) : bits_t 4 =>
         if (tracker[|2`d0|]) then
            ToRouter.(MessageFifo1.enq_req)(struct cache_mem_req {| core_id := Ob~0;
                                                                    cache_type := enum cache_type {| imem |};
                                                                    addr := addr;
                                                                    MSI_state := enum MSI {| I |}
                                                                 |});
            tracker[|2`d1|:+3] ++ Ob~0
          else if (tracker[|2`d1|]) then
            ToRouter.(MessageFifo1.enq_req)(struct cache_mem_req {| core_id := Ob~0;
                                                                    cache_type := enum cache_type {| dmem |};
                                                                    addr := addr;
                                                                    MSI_state := enum MSI {| I |}
                                                                 |});
            tracker[|2`d2|:+2] ++ Ob~0~0
          else if (tracker[|2`d1|]) then
            ToRouter.(MessageFifo1.enq_req)(struct cache_mem_req {| core_id := Ob~1;
                                                                    cache_type := enum cache_type {| imem |};
                                                                    addr := addr;
                                                                    MSI_state := enum MSI {| I |}
                                                                 |});

            tracker[|2`d3|] ++ Ob~0~0~0
          else if (tracker[|2`d1|]) then
            ToRouter.(MessageFifo1.enq_req)(struct cache_mem_req {| core_id := Ob~1;
                                                                    cache_type := enum cache_type {| dmem |};
                                                                    addr := addr;
                                                                    MSI_state := enum MSI {| I |}
                                                                 |});
            Ob~0~0~0~0
          else Ob~0~0~0~0
    }}.

  (* If Core is trying to load,
   * - if other has state M, issue downgrade request to S and grab line from them
   * - if no one has state M, issue memory request
   *   (then give core state S)
   *
   * If Core is trying to store,
   * - for al with state M or S, issue downgrade request to I
   * - if other has state M, grab line from them
   *     else issue memory request
   *   (core is then given state M)
   *)
  Definition receive_upgrade_requests: uaction reg_t ext_fn_t :=
    {{
        let ushr := read0(internal ushr) in
        guard (!FromRouter.(MessageFifo1.has_resp)() &&
                FromRouter.(MessageFifo1.has_req)() &&
                (get(ushr, state) == enum USHR_state {| Ready |})
              );
        let req := get(FromRouter.(MessageFifo1.deq)(),req) in
        let addr := get(req,addr) in

        let tag := getTag(addr) in
        let index := getIndex(addr) in
        let core_id := get(req,core_id) in
        let other_core_has_line := has_line(index, tag, !core_id) in
        write0(internal bypass, {invalid (data_t)}());
        (* Load *)
        if (get(req,MSI_state) == enum MSI {| S |}) then
          write0(internal ushr, struct USHR {| state := enum USHR_state {| Confirming |};
                                               req := req |});
          if (other_core_has_line) then
            (* Parent !get(req,core_id) has the line, issue downgrade to S *)
            ToRouter.(MessageFifo1.enq_req)(struct cache_mem_req {| core_id := !core_id;
                                                                    cache_type := enum cache_type {| dmem |};
                                                                    addr := addr;
                                                                    MSI_state := enum MSI {| S |}
                                                                 |})
          else
            (* No one has the line, request from memory *)
            ToMem.(MemReq.enq)(struct mem_req {| byte_en := Ob~0~0~0~0;
                                                 addr := addr;
                                                 data := |32`d0| |})
        (* Store *)
        else if (get(req,MSI_state) == enum MSI {| M |}) then
          (when (!other_core_has_line) do (* TODO: core doesn't have the line *)
            (* Request line from main memory *)
            ToMem.(MemReq.enq)(struct mem_req {| byte_en := Ob~0~0~0~0;
                                                 addr := addr;
                                                 data := |32`d0| |}));
          (* For all lines that are M/S, downgrade to I: it's either the case that
           * there is one M core (others I), or mix of S/I cores *)
          let downgrade_tracker :=
              set_invalid_at_cache(compute_downgrade_tracker(index, tag),
                                   core_id, get(req, cache_type)) in
          let tracker2 := do_downgrade_from_tracker(addr, downgrade_tracker) in
          write0(internal downgrade_tracker, tracker2);
          if (tracker2 == |4`d0|) then
            (* done issuing downgrade requests *)
            write0(internal ushr, struct USHR {| state := enum USHR_state {| Downgrading |};
                                                 req := req |})
          else
            write0(internal ushr, struct USHR {| state := enum USHR_state {| Confirming |};
                                                 req := req |})
        else pass (* Should not happen? Could do fail for ease of debugging *)
    }}.

  Definition issue_downgrades: uaction reg_t ext_fn_t :=
    {{
        let ushr := read0(internal ushr) in
        guard(get(ushr, state) == enum USHR_state {| Downgrading |});
        let req := get(ushr,req) in
        let tracker := read0(internal downgrade_tracker) in
        let tracker2 := do_downgrade_from_tracker(get(req,addr), tracker) in
        write0(internal downgrade_tracker, tracker2);
        (when (tracker2 == |4`d0|) do
            (write0(internal ushr, struct USHR {| state := enum USHR_state {| Confirming |};
                                                 req := req |})))
    }}.

  Definition dummy_cache_mem_req : struct_t cache_mem_req := value_of_bits (Bits.zero).

  Definition confirm_downgrades: uaction reg_t ext_fn_t :=
    {{ let ushr := read0(internal ushr) in
       guard(get(ushr, state) == enum USHR_state {| Confirming |});
       let req := get(ushr,req) in
       let addr := get(req,addr) in
       (* Either load req, or store req and all states are invalid other than core's *)
       let states := compute_downgrade_tracker (getIndex(addr), getTag(addr)) in
       let states2 := set_invalid_at_cache(states, get(req,core_id),get(req,cache_type)) in
       if ((get(req, MSI_state) == enum MSI {| S |}) ||
           states2 == Ob~0~0~0~0) then
         let data := {invalid (data_t)}() in
         let bypass_opt := read1(internal bypass) in
         (
           (* if (getState(addr,child) != I) then *)
         if (states[cache_encoding(get(req,core_id), get(req,cache_type))]) then
            pass (* (data = invalid) *)
         else if (get(bypass_opt,valid)) then
              set data := bypass_opt
         else
           let resp := FromMem.(MemResp.deq)() in
           set data := {valid data_t} (get(resp, data))
         );
         (* Parent sending response to child *)
         ToRouter.(MessageFifo1.enq_resp)(
                      struct cache_mem_resp {| core_id := get(req, core_id);
                                               cache_type := get(req, cache_type);
                                               addr := addr;
                                               MSI_state := get(req, MSI_state);
                                               data := data
                                            |});
         let input := struct bookkeeping_input
                            {| idx := getIndex(addr);
                               book := {valid (struct_t Bookkeeping_row)}(
                                           struct Bookkeeping_row {| state := get(req, MSI_state);
                                                                     tag := getTag(addr)
                                                                  |});
                               core_id := get(req,core_id);
                               cache_type := get(req, cache_type)
                           |} in
         ignore(extcall ext_ppp_bookkeeping (input));
         write0(internal ushr, struct USHR {| state := enum USHR_state {| Ready |};
                                              req := `UConst dummy_cache_mem_req` |})
       else pass
    }}.

  (*
  Definition forward_req: uaction reg_t empty_ext_fn_t :=
    {{
        let ushr := read0(internal ushr) in
        guard (!FromRouter.(MessageFifo1.has_resp)() &&
                FromRouter.(MessageFifo1.has_req)() &&
                (get(ushr, state) == enum USHR_state {| Ready |})
              );
        let req := get(FromRouter.(MessageFifo1.deq)(),req) in
        (* For now, just forward *)
        ToMem.(MemReq.enq)(struct mem_req {| byte_en := Ob~0~0~0~0;
                                             addr := get(req,addr);
                                             data := |32`d0| |});
        write0(internal ushr, struct USHR {| state := enum USHR_state {| Confirming |};
                                             req := req |})
    }}.
    *)

    (*
  Definition dummy_cache_mem_req : struct_t cache_mem_req := value_of_bits (Bits.zero).

  Definition forward_resp_from_mem : uaction reg_t empty_ext_fn_t :=
    {{ let ushr := read0(internal ushr) in
       guard(get(ushr, state) == enum USHR_state {| Confirming |});
       let resp := FromMem.(MemResp.deq)() in
       let req_info := get(ushr, req) in
       ToRouter.(MessageFifo1.enq_resp)(
                    struct cache_mem_resp {| core_id := get(req_info, core_id);
                                             cache_type := get(req_info, cache_type);
                                             addr := get(resp, addr);
                                             MSI_state := get(req_info, MSI_state);
                                             data := {valid data_t} (get(resp, data))
                                          |});
       write0(internal ushr, struct USHR {| state := enum USHR_state {| Ready |};
                                            req := `UConst dummy_cache_mem_req` |})
    }}.
    *)

  Inductive rule_name_t :=
  | Rl_ReceiveResp
  | Rl_ReceiveUpgradeReqs
  | Rl_IssueDowngrades
  | Rl_ConfirmDowngrades.

  Definition rule := rule R Sigma.

  Definition tc_receiveResp := tc_rule R Sigma receive_responses <: rule.
  Definition tc_receiveUpgradeReqs := tc_rule R Sigma receive_upgrade_requests <: rule.
  Definition tc_issueDowngrades := tc_rule R Sigma issue_downgrades <: rule.
  Definition tc_confirmDowngrades := tc_rule R Sigma confirm_downgrades <: rule.

  Definition rules (rl: rule_name_t) : rule :=
    match rl with
    | Rl_ReceiveResp => tc_receiveResp
    | Rl_ReceiveUpgradeReqs => tc_receiveUpgradeReqs
    | Rl_IssueDowngrades => tc_issueDowngrades
    | Rl_ConfirmDowngrades => tc_confirmDowngrades
    end.

  Definition schedule : Syntax.scheduler pos_t rule_name_t :=
    Rl_ReceiveResp |> Rl_ReceiveUpgradeReqs |> Rl_IssueDowngrades |> Rl_ConfirmDowngrades |> done.

End ProtocolProcessor.

Module MainMem.
  Import Common.
  Inductive reg_t :=
  | FromProto (state: MemReq.reg_t)
  | ToProto   (state: MemResp.reg_t)
  .

  Definition R idx : type :=
    match idx with
    | FromProto st => MemReq.R st
    | ToProto st => MemResp.R st
    end.

  Import External.

  Definition ext_fn_t := External.ext_fn_t.
  Definition Sigma := External.Sigma.
  Definition rule := rule R Sigma.

  Definition MMIO_UART_ADDRESS := Ob~0~1~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0.
  Definition MMIO_LED_ADDRESS  := Ob~0~1~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~1~0~0.

  Definition mainMemoryBus : UInternalFunction reg_t ext_fn_t :=
    {{ fun memoryBus (get_ready: bits_t 1) (put_valid: bits_t 1) (put_request: struct_t mem_req) : struct_t mem_output=>
       extcall (ext_mainmem)
               (struct mem_input {|
                          get_ready := get_ready;
                          put_valid := put_valid;
                          put_request := put_request |})
    }}.

  Definition mem : uaction reg_t ext_fn_t :=
    let fromMem := ToProto in
    let toMem := FromProto in
    {{
        let get_ready := fromMem.(MemResp.can_enq)() in
        let put_request_opt := toMem.(MemReq.peek)() in
        let put_request := get(put_request_opt, data) in
        let put_valid := get(put_request_opt, valid) in
        let mem_out := mainMemoryBus(get_ready, put_valid, put_request) in
        (when (get_ready && get(mem_out, get_valid)) do fromMem.(MemResp.enq)(get(mem_out, get_response)));
        (when (put_valid && get(mem_out, put_ready)) do ignore(toMem.(MemReq.deq)()))
    }}.

  Definition tc_mem := tc_rule R Sigma mem <: rule.

  Inductive rule_name_t :=
  | Rl_mem
  .

  Definition rules (rl: rule_name_t) : rule :=
    match rl with
    | Rl_mem => tc_mem
    end.

  Definition schedule : Syntax.scheduler pos_t rule_name_t :=
    Rl_mem |> done.

End MainMem.

Module WIPMemory <: Memory_sig External.
  Import Common.

  (* This memory has two L1 I&D caches, a message router, and protocol processor, and the main memory.
   * TODO: next we will add a L2 cache.
   *)

  Import CacheTypes.

  Module Params_Core0IMem <: CacheParams.
    Definition _core_id := CoreId0.
    Definition _cache_type := CacheType_Imem.
  End Params_Core0IMem.

  Module Params_Core0DMem <: CacheParams.
    Definition _core_id := CoreId0.
    Definition _cache_type := CacheType_Dmem. (* dmem *)
  End Params_Core0DMem.

  Module Params_Core1IMem <: CacheParams.
    Definition _core_id := CoreId1.
    Definition _cache_type := CacheType_Imem. (* imem *)
  End Params_Core1IMem.

  Module Params_Core1DMem <: CacheParams.
    Definition _core_id := CoreId1.
    Definition _cache_type := CacheType_Dmem.
  End Params_Core1DMem.

  Module Core0IMem := Cache Params_Core0IMem.
  Module Core0DMem := Cache Params_Core0DMem.
  Module Core1IMem := Cache Params_Core1IMem.
  Module Core1DMem := Cache Params_Core0DMem.

  (* TODO: In theory we would do this in a more modular way, but we simplify for now.
   *)
  Inductive internal_reg_t' : Type :=
  | core0IToRouter (state: MessageFifo1.reg_t)
  | core0DToRouter (state: MessageFifo1.reg_t)
  | core1IToRouter (state: MessageFifo1.reg_t)
  | core1DToRouter (state: MessageFifo1.reg_t)
  | RouterToCore0I (state: MessageFifo1.reg_t)
  | RouterToCore0D (state: MessageFifo1.reg_t)
  | RouterToCore1I (state: MessageFifo1.reg_t)
  | RouterToCore1D (state: MessageFifo1.reg_t)
  | RouterToProto (state: MessageFifo1.reg_t)
  | ProtoToRouter (state: MessageFifo1.reg_t)
  | ProtoToMem (state: MemReq.reg_t)
  | MemToProto (state: MemResp.reg_t)
  | Router_internal (state: MessageRouter.internal_reg_t)
  | Proto_internal (state: ProtocolProcessor.internal_reg_t)
  | Core0I_internal (state: Core0IMem.internal_reg_t)
  | Core0D_internal (state: Core0DMem.internal_reg_t)
  | Core1I_internal (state: Core1IMem.internal_reg_t)
  | Core1D_internal (state: Core1DMem.internal_reg_t)
  .

  Definition internal_reg_t := internal_reg_t'.

  Definition R_internal (idx: internal_reg_t) : type :=
    match idx with
    | core0IToRouter st => MessageFifo1.R st
    | core0DToRouter st => MessageFifo1.R st
    | core1IToRouter st => MessageFifo1.R st
    | core1DToRouter st => MessageFifo1.R st
    | RouterToCore0I st => MessageFifo1.R st
    | RouterToCore0D st => MessageFifo1.R st
    | RouterToCore1I st => MessageFifo1.R st
    | RouterToCore1D st => MessageFifo1.R st
    | RouterToProto st => MessageFifo1.R st
    | ProtoToRouter st => MessageFifo1.R st
    | ProtoToMem st => MemReq.R st
    | MemToProto st => MemResp.R st
    | Router_internal st => MessageRouter.R_internal st
    | Proto_internal st => ProtocolProcessor.R_internal st
    | Core0I_internal st => Core0IMem.R_internal st
    | Core0D_internal st => Core0DMem.R_internal st
    | Core1I_internal st => Core1IMem.R_internal st
    | Core1D_internal st => Core1DMem.R_internal st
    end.

  Definition r_internal (idx: internal_reg_t) : R_internal idx :=
    match idx with
    | core0IToRouter st => MessageFifo1.r st
    | core0DToRouter st => MessageFifo1.r st
    | core1IToRouter st => MessageFifo1.r st
    | core1DToRouter st => MessageFifo1.r st
    | RouterToCore0I st => MessageFifo1.r st
    | RouterToCore0D st => MessageFifo1.r st
    | RouterToCore1I st => MessageFifo1.r st
    | RouterToCore1D st => MessageFifo1.r st
    | RouterToProto st => MessageFifo1.r st
    | ProtoToRouter st => MessageFifo1.r st
    | ProtoToMem st => MemReq.r st
    | MemToProto st => MemResp.r st
    | Router_internal st => MessageRouter.r_internal st
    | Proto_internal st => ProtocolProcessor.r_internal st
    | Core0I_internal st => Core0IMem.r_internal st
    | Core0D_internal st => Core0DMem.r_internal st
    | Core1I_internal st => Core1IMem.r_internal st
    | Core1D_internal st => Core1DMem.r_internal st
    end.

  Instance FiniteType_internal_reg_t : FiniteType internal_reg_t := _.

  Inductive reg_t :=
  | toIMem0 (state: MemReq.reg_t)
  | toIMem1 (state: MemReq.reg_t)
  | toDMem0 (state: MemReq.reg_t)
  | toDMem1 (state: MemReq.reg_t)
  | fromIMem0 (state: MemResp.reg_t)
  | fromIMem1 (state: MemResp.reg_t)
  | fromDMem0 (state: MemResp.reg_t)
  | fromDMem1 (state: MemResp.reg_t)
  | internal (r: internal_reg_t)
  .

  Definition R (idx: reg_t) :=
    match idx with
    | toIMem0 st => MemReq.R st
    | toIMem1 st => MemReq.R st
    | toDMem0 st => MemReq.R st
    | toDMem1 st => MemReq.R st
    | fromIMem0 st => MemResp.R st
    | fromIMem1 st => MemResp.R st
    | fromDMem0 st => MemResp.R st
    | fromDMem1 st => MemResp.R st
    | internal st => R_internal st
    end.

  Definition r idx : R idx :=
    match idx with
    | toIMem0 st => MemReq.r st
    | toIMem1 st => MemReq.r st
    | toDMem0 st => MemReq.r st
    | toDMem1 st => MemReq.r st
    | fromIMem0 st => MemResp.r st
    | fromIMem1 st => MemResp.r st
    | fromDMem0 st => MemResp.r st
    | fromDMem1 st => MemResp.r st
    | internal st => r_internal st
    end.

  Definition ext_fn_t := External.ext_fn_t.
  Definition Sigma := External.Sigma.
  Definition rule := rule R Sigma.
  (* Definition sigma := External.sigma. *)

  Notation "'__internal__' instance " :=
    (fun reg => internal ((instance) reg)) (in custom koika at level 1, instance constr at level 99).
  Notation "'(' instance ').(' method ')' args" :=
    (USugar (UCallModule instance _ method args))
      (in custom koika at level 1, method constr, args custom koika_args at level 99).

  Import External.

  (* =============== Lifts ================ *)

  Section Core0_IMemLift.
    Definition core0_imem_lift (reg: Core0IMem.reg_t) : reg_t :=
      match reg with
      | Core0IMem.fromMem st => (internal (RouterToCore0I st))
      | Core0IMem.toMem st => (internal (core0IToRouter st))
      | Core0IMem.internal st => (internal (Core0I_internal st))
      end.

    Definition Lift_core0_imem : RLift _ Core0IMem.reg_t reg_t Core0IMem.R R := ltac:(mk_rlift core0_imem_lift).
    Definition FnLift_core0_imem : RLift _ Core0IMem.ext_fn_t ext_fn_t Core0IMem.Sigma Sigma := ltac:(lift_auto).

  End Core0_IMemLift.

  Section Core0_DMemLift.
    Definition core0_dmem_lift (reg: Core0DMem.reg_t) : reg_t :=
      match reg with
      | Core0DMem.fromMem st => (internal (RouterToCore0D st))
      | Core0DMem.toMem st => (internal (core0DToRouter st))
      | Core0DMem.internal st => (internal (Core0D_internal st))
      end.

    Definition Lift_core0_dmem : RLift _ Core0DMem.reg_t reg_t Core0DMem.R R := ltac:(mk_rlift core0_dmem_lift).
    Definition FnLift_core0_dmem : RLift _ Core0DMem.ext_fn_t ext_fn_t Core0DMem.Sigma Sigma := ltac:(lift_auto).

  End Core0_DMemLift.

  (* TODO: Core1 *)
  Section MessageRouterLift.
    Definition router_lift (reg: MessageRouter.reg_t) : reg_t :=
    match reg with
    | MessageRouter.FromCore0I st => (internal (core0IToRouter st))
    | MessageRouter.FromCore0D st => (internal (core0DToRouter st))
    | MessageRouter.FromCore1I st => (internal (core1IToRouter st))
    | MessageRouter.FromCore1D st => (internal (core1DToRouter st))
    | MessageRouter.ToCore0I st => (internal (RouterToCore0I st))
    | MessageRouter.ToCore0D st => (internal (RouterToCore0D st))
    | MessageRouter.ToCore1I st => (internal (RouterToCore1I st))
    | MessageRouter.ToCore1D st => (internal (RouterToCore1D st))
    | MessageRouter.ToProto st => (internal (RouterToProto st))
    | MessageRouter.FromProto st => (internal (ProtoToRouter st))
    | MessageRouter.internal st => (internal (Router_internal st))
    end.

    Definition Lift_router : RLift _ MessageRouter.reg_t reg_t MessageRouter.R R := ltac:(mk_rlift router_lift).
    Definition FnLift_router : RLift _ MessageRouter.ext_fn_t ext_fn_t MessageRouter.Sigma Sigma := ltac:(lift_auto).

  End MessageRouterLift.

  Section ProtocolProcessorLift.

    Definition proto_lift (reg: ProtocolProcessor.reg_t) : reg_t :=
    match reg with
    | ProtocolProcessor.FromRouter st => (internal (RouterToProto st))
    | ProtocolProcessor.ToRouter st => (internal (ProtoToRouter st ))
    | ProtocolProcessor.ToMem st => (internal (ProtoToMem st))
    | ProtocolProcessor.FromMem st => (internal (MemToProto st))
    | ProtocolProcessor.internal st => (internal (Proto_internal st))
    end.

    Definition Lift_proto : RLift _ ProtocolProcessor.reg_t reg_t ProtocolProcessor.R R := ltac:(mk_rlift proto_lift).
    Definition FnLift_proto : RLift _ ProtocolProcessor.ext_fn_t ext_fn_t ProtocolProcessor.Sigma Sigma := ltac:(lift_auto).

  End ProtocolProcessorLift.

  Section MainMemLift.
    Definition main_mem_lift (reg: MainMem.reg_t) : reg_t :=
      match reg with
      | MainMem.FromProto st => internal (ProtoToMem st)
      | MainMem.ToProto st => internal (MemToProto st)
      end.

    Definition Lift_main_mem: RLift _ MainMem.reg_t reg_t MainMem.R R := ltac:(mk_rlift main_mem_lift).
    Definition FnLift_main_mem: RLift _ MainMem.ext_fn_t ext_fn_t MainMem.Sigma Sigma := ltac:(lift_auto).
  End MainMemLift.

  (* TODO: slow *)
  Instance FiniteType_reg_t : FiniteType reg_t := _.
  (* Declare Instance FiniteType_reg_t : FiniteType reg_t.   *)
  Instance EqDec_reg_t : EqDec reg_t := _.

  Definition MMIO_UART_ADDRESS := Ob~0~1~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0.
  Definition MMIO_LED_ADDRESS  := Ob~0~1~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~1~0~0.

  Definition memoryBus (m: External.cache) : UInternalFunction reg_t ext_fn_t :=
    {{ fun memoryBus (get_ready: bits_t 1) (put_valid: bits_t 1) (put_request: struct_t mem_req)
         : maybe (struct_t mem_output) =>
         `match m with
          | imem => {{ {invalid (struct_t mem_output) }() }}
          | dmem    => {{
                      let addr := get(put_request, addr) in
                      let byte_en := get(put_request, byte_en) in
                      let is_write := byte_en == Ob~1~1~1~1 in

                      let is_uart := addr == #MMIO_UART_ADDRESS in
                      let is_uart_read := is_uart && !is_write in
                      let is_uart_write := is_uart && is_write in

                      let is_led := addr == #MMIO_LED_ADDRESS in
                      let is_led_write := is_led && is_write in

                      let is_mem := !is_uart && !is_led in

                      if is_uart_write then
                        let char := get(put_request, data)[|5`d0| :+ 8] in
                        let may_run := get_ready && put_valid && is_uart_write in
                        let ready := extcall ext_uart_write (struct (Maybe (bits_t 8)) {|
                          valid := may_run; data := char |}) in
                        {valid (struct_t mem_output)}(
                          struct mem_output {| get_valid := may_run && ready;
                                               put_ready := may_run && ready;
                                               get_response := struct mem_resp {|
                                                 byte_en := byte_en; addr := addr;
                                                 data := |32`d0| |} |})

                      else if is_uart_read then
                        let may_run := get_ready && put_valid && is_uart_read in
                        let opt_char := extcall ext_uart_read (may_run) in
                        let ready := get(opt_char, valid) in
                        {valid (struct_t mem_output)}(
                          struct mem_output {| get_valid := may_run && ready;
                                               put_ready := may_run && ready;
                                               get_response := struct mem_resp {|
                                                 byte_en := byte_en; addr := addr;
                                                 data := zeroExtend(get(opt_char, data), 32) |} |})

                      else if is_led then
                        let on := get(put_request, data)[|5`d0|] in
                        let may_run := get_ready && put_valid && is_led_write in
                        let current := extcall ext_led (struct (Maybe (bits_t 1)) {|
                          valid := may_run; data := on |}) in
                        let ready := Ob~1 in
                        {valid (struct_t mem_output)}(
                          struct mem_output {| get_valid := may_run && ready;
                                               put_ready := may_run && ready;
                                               get_response := struct mem_resp {|
                                                 byte_en := byte_en; addr := addr;
                                                 data := zeroExtend(current, 32) |} |})

                      else
                        {invalid (struct_t mem_output)}()
                   }}
          end` }} .

  Section SystemRules.
    Definition memCore0I : uaction reg_t ext_fn_t :=
      let fromMem := fromIMem0 in
      let toMem := toIMem0 in
      {{
          let get_ready := fromMem.(MemResp.can_enq)() in
          let put_request_opt := toMem.(MemReq.peek)() in
          let put_request := get(put_request_opt, data) in
          let put_valid := get(put_request_opt, valid) in

          let mem_out_opt := {memoryBus imem}(get_ready, put_valid, put_request) in
          if (get(mem_out_opt,valid)) then
            (* valid output *)
            let mem_out := get(mem_out_opt,data) in
            (when (get_ready && get(mem_out, get_valid)) do fromMem.(MemResp.enq)(get(mem_out, get_response)));
            (when (put_valid && get(mem_out, put_ready)) do ignore(toMem.(MemReq.deq)()))
          else
            (* TODO: these rules can fail *)
            (when (put_valid && (`core0_imem_lift`).(Core0IMem.can_send_req)()) do (
              ignore(toMem.(MemReq.deq)());
              (`core0_imem_lift`).(Core0IMem.req)(put_request)
            ));
            (when (get_ready && (`core0_imem_lift`).(Core0IMem.can_recv_resp)()) do (
              let resp := (`core0_imem_lift`).(Core0IMem.resp)() in
              fromMem.(MemResp.enq)(resp))
            )
      }}.

    Definition tc_memCore0I := tc_rule R Sigma memCore0I <: rule.

    Definition memCore0D : uaction reg_t ext_fn_t :=
      let fromMem := fromDMem0 in
      let toMem := toDMem0 in
      {{
          let get_ready := fromMem.(MemResp.can_enq)() in
          let put_request_opt := toMem.(MemReq.peek)() in
          let put_request := get(put_request_opt, data) in
          let put_valid := get(put_request_opt, valid) in

          let mem_out_opt := {memoryBus dmem}(get_ready, put_valid, put_request) in
          if (get(mem_out_opt,valid)) then
            (* valid output *)
            let mem_out := get(mem_out_opt,data) in
            (when (get_ready && get(mem_out, get_valid)) do fromMem.(MemResp.enq)(get(mem_out, get_response)));
            (when (put_valid && get(mem_out, put_ready)) do ignore(toMem.(MemReq.deq)()))
          else
            (* TODO: these rules can fail *)
            (when (put_valid && (`core0_dmem_lift`).(Core0DMem.can_send_req)()) do (
              ignore(toMem.(MemReq.deq)());
              (`core0_dmem_lift`).(Core0DMem.req)(put_request)
            ));
            (when (get_ready && (`core0_dmem_lift`).(Core0DMem.can_recv_resp)()) do (
              let resp := (`core0_dmem_lift`).(Core0DMem.resp)() in
              fromMem.(MemResp.enq)(resp))
            )
      }}.

    Definition tc_memCore0D := tc_rule R Sigma memCore0D <: rule.

    Inductive SystemRule :=
    | SysRl_MemCore0I
    | SysRl_MemCore0D
    .

    Definition system_rules (rl: SystemRule) : rule :=
      match rl with
      | SysRl_MemCore0I => tc_memCore0I
      | SysRl_MemCore0D => tc_memCore0D
      end.

    Definition internal_system_schedule : Syntax.scheduler pos_t SystemRule :=
      SysRl_MemCore0I |> SysRl_MemCore0D |> done.

  End SystemRules.

  Section Rules.
    Inductive rule_name_t' :=
    | Rl_System (r: SystemRule)
    | Rl_Core0IMem (r: Core0IMem.rule_name_t)
    | Rl_Core0DMem (r: Core0DMem.rule_name_t)
    | Rl_Proto (r: ProtocolProcessor.rule_name_t)
    | Rl_Router (r: MessageRouter.rule_name_t)
    | Rl_MainMem (r: MainMem.rule_name_t)
    .

    Definition rule_name_t := rule_name_t'.

    Definition core0I_rule_name_lift (rl: Core0IMem.rule_name_t) : rule_name_t :=
      Rl_Core0IMem rl.

    Definition core0D_rule_name_lift (rl: Core0DMem.rule_name_t) : rule_name_t :=
      Rl_Core0DMem rl.

    Definition proto_rule_name_lift (rl: ProtocolProcessor.rule_name_t) : rule_name_t :=
      Rl_Proto rl.

    Definition router_rule_name_lift (rl: MessageRouter.rule_name_t) : rule_name_t :=
      Rl_Router rl.

    Definition main_mem_name_lift (rl: MainMem.rule_name_t) : rule_name_t :=
      Rl_MainMem rl.

    Definition core0I_rules (rl: Core0IMem.rule_name_t) : rule :=
      lift_rule Lift_core0_imem FnLift_core0_imem (Core0IMem.rules rl).
    Definition core0D_rules (rl: Core0DMem.rule_name_t) : rule :=
      lift_rule Lift_core0_dmem FnLift_core0_dmem (Core0DMem.rules rl).
    Definition proto_rules (rl: ProtocolProcessor.rule_name_t) : rule :=
      lift_rule Lift_proto FnLift_proto (ProtocolProcessor.rules rl).
    Definition router_rules (rl: MessageRouter.rule_name_t) : rule :=
      lift_rule Lift_router FnLift_router (MessageRouter.rules rl).
    Definition main_mem_rules (rl: MainMem.rule_name_t) : rule :=
      lift_rule Lift_main_mem FnLift_main_mem (MainMem.rules rl).

    Definition rules (rl: rule_name_t) : rule :=
      match rl with
      | Rl_System r => system_rules r
      | Rl_Core0IMem r => core0I_rules r
      | Rl_Core0DMem r => core0D_rules r
      | Rl_Proto r => proto_rules r
      | Rl_Router r => router_rules r
      | Rl_MainMem r => main_mem_rules r
     end.

  End Rules.

  Section Schedule.
    Definition system_schedule := lift_scheduler Rl_System internal_system_schedule.
    Definition core0I_schedule := lift_scheduler Rl_Core0IMem Core0IMem.schedule.
    Definition core0D_schedule := lift_scheduler Rl_Core0DMem  Core0DMem.schedule.
    Definition proto_schedule := lift_scheduler Rl_Proto ProtocolProcessor.schedule.
    Definition router_schedule := lift_scheduler Rl_Router MessageRouter.schedule.
    Definition main_mem_schedule := lift_scheduler Rl_MainMem MainMem.schedule.

    Definition schedule :=
      system_schedule ||> core0I_schedule ||> core0D_schedule ||> router_schedule
                      ||> proto_schedule ||> main_mem_schedule.

  End Schedule.

End WIPMemory.

(*
Module SimpleMemory <: Memory_sig OriginalExternal.
  Import Common.

  (* TOOD: Silly workaround due to extraction issues: https://github.com/coq/coq/issues/12124 *)
  Inductive internal_reg_t' : Type :=
  | Foo | Bar .

  Definition internal_reg_t := internal_reg_t'.

  Definition R_internal (idx: internal_reg_t) : type :=
    match idx with
    | Foo => bits_t 1
    | Bar => bits_t 1
    end.

  Definition r_internal (idx: internal_reg_t) : R_internal idx :=
    match idx with
    | Foo => Bits.zero
    | Bar => Bits.zero
    end.

  Inductive reg_t :=
  | toIMem0 (state: MemReq.reg_t)
  | toIMem1 (state: MemReq.reg_t)
  | toDMem0 (state: MemReq.reg_t)
  | toDMem1 (state: MemReq.reg_t)
  | fromIMem0 (state: MemResp.reg_t)
  | fromIMem1 (state: MemResp.reg_t)
  | fromDMem0 (state: MemResp.reg_t)
  | fromDMem1 (state: MemResp.reg_t)
  | internal (r: internal_reg_t)
  .

  Definition R (idx: reg_t) :=
    match idx with
    | toIMem0 st => MemReq.R st
    | toIMem1 st => MemReq.R st
    | toDMem0 st => MemReq.R st
    | toDMem1 st => MemReq.R st
    | fromIMem0 st => MemResp.R st
    | fromIMem1 st => MemResp.R st
    | fromDMem0 st => MemResp.R st
    | fromDMem1 st => MemResp.R st
    | internal st => R_internal st
    end.

  Definition r idx : R idx :=
    match idx with
    | toIMem0 st => MemReq.r st
    | toIMem1 st => MemReq.r st
    | toDMem0 st => MemReq.r st
    | toDMem1 st => MemReq.r st
    | fromIMem0 st => MemResp.r st
    | fromIMem1 st => MemResp.r st
    | fromDMem0 st => MemResp.r st
    | fromDMem1 st => MemResp.r st
    | internal st => r_internal st
    end.

  Definition ext_fn_t := OriginalExternal.ext_fn_t.
  Definition Sigma := OriginalExternal.Sigma.
  Definition rule := rule R Sigma.
  (* Definition sigma := External.sigma. *)


  Definition MMIO_UART_ADDRESS := Ob~0~1~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0.
  Definition MMIO_LED_ADDRESS  := Ob~0~1~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~1~0~0.

  Import OriginalExternal.

  Definition memoryBus (m: memory) : UInternalFunction reg_t ext_fn_t :=
    {{ fun memoryBus (get_ready: bits_t 1) (put_valid: bits_t 1) (put_request: struct_t mem_req) : struct_t mem_output =>
         `match m with
          | imem =>  {{ extcall (ext_mem imem) (struct mem_input {|
                         get_ready := get_ready;
                         put_valid := put_valid;
                         put_request := put_request |}) }}
          | dmem =>  {{ let addr := get(put_request, addr) in
                       let byte_en := get(put_request, byte_en) in
                       let is_write := byte_en == Ob~1~1~1~1 in

                       let is_uart := addr == #MMIO_UART_ADDRESS in
                       let is_uart_read := is_uart && !is_write in
                       let is_uart_write := is_uart && is_write in

                       let is_led := addr == #MMIO_LED_ADDRESS in
                       let is_led_write := is_led && is_write in

                       let is_mem := !is_uart && !is_led in

                       if is_uart_write then
                         let char := get(put_request, data)[|5`d0| :+ 8] in
                         let may_run := get_ready && put_valid && is_uart_write in
                         let ready := extcall ext_uart_write (struct (Maybe (bits_t 8)) {|
                           valid := may_run; data := char |}) in
                         struct mem_output {| get_valid := may_run && ready;
                                              put_ready := may_run && ready;
                                              get_response := struct mem_resp {|
                                                byte_en := byte_en; addr := addr;
                                                data := |32`d0| |} |}

                       else if is_uart_read then
                         let may_run := get_ready && put_valid && is_uart_read in
                         let opt_char := extcall ext_uart_read (may_run) in
                         let ready := get(opt_char, valid) in
                         struct mem_output {| get_valid := may_run && ready;
                                              put_ready := may_run && ready;
                                              get_response := struct mem_resp {|
                                                byte_en := byte_en; addr := addr;
                                                data := zeroExtend(get(opt_char, data), 32) |} |}

                       else if is_led then
                         let on := get(put_request, data)[|5`d0|] in
                         let may_run := get_ready && put_valid && is_led_write in
                         let current := extcall ext_led (struct (Maybe (bits_t 1)) {|
                           valid := may_run; data := on |}) in
                         let ready := Ob~1 in
                         struct mem_output {| get_valid := may_run && ready;
                                              put_ready := may_run && ready;
                                              get_response := struct mem_resp {|
                                                byte_en := byte_en; addr := addr;
                                                data := zeroExtend(current, 32) |} |}

                       else
                         extcall (ext_mem dmem) (struct mem_input {|
                           get_ready := get_ready && is_mem;
                           put_valid := put_valid && is_mem;
                           put_request := put_request |})
                   }}
          end` }}.

  (* TODO: not defined for main_mem *)
  Definition mem (m: memory) : uaction reg_t ext_fn_t :=
    let fromMem := match m with imem0 => fromIMem0 | dmem0 => fromDMem0 end in
    let toMem := match m with imem0 => toIMem0 | dmem0 => toDMem0 end in
    {{
        let get_ready := fromMem.(MemResp.can_enq)() in
        let put_request_opt := toMem.(MemReq.peek)() in
        let put_request := get(put_request_opt, data) in
        let put_valid := get(put_request_opt, valid) in
        let mem_out := {memoryBus m}(get_ready, put_valid, put_request) in
        (when (get_ready && get(mem_out, get_valid)) do fromMem.(MemResp.enq)(get(mem_out, get_response)));
        (when (put_valid && get(mem_out, put_ready)) do ignore(toMem.(MemReq.deq)()))
    }}.

  Definition tc_imem := tc_rule R Sigma (mem imem) <: rule.
  Definition tc_dmem := tc_rule R Sigma (mem dmem) <: rule.

  Inductive rule_name_t' :=
  | Imem
  | Dmem
  .

  Definition rule_name_t := rule_name_t'.

  Definition rules (rl: rule_name_t) : rule :=
    match rl with
    | Imem           => tc_imem
    | Dmem           => tc_dmem
    end.

  Definition schedule : scheduler :=
    Imem |> Dmem |> done.

  Instance FiniteType_internal_reg_t : FiniteType internal_reg_t := _.
  Instance FiniteType_reg_t : FiniteType reg_t := _.
End SimpleMemory.
*)
