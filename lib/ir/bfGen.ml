open Support.Pervasive

let gen_bf (layout: Layout.t) (code: 'a Code.t): Bf.Code.t =
  let code = Code.delete_annot code in
  let rec gen_bf (pos_init: Pos.t) (code: unit Code.t) =
    let pos, bf_code_llist =
      LList.fold_left_map
        (fun pos Code.{ cmd; _ }: (Pos.t * Bf.Code.t) ->
          match cmd with
          | Add (0, _) -> (pos, ~~[])
          | Add (n, sel) ->
              let pos_dest = Pos.from_sel_to_cell layout sel in
              (pos_dest, Pos.gen_bf_move pos pos_dest @+ ~~[ Bf.Code.Add n ])
          | Put sel ->
              let pos_dest = Pos.from_sel_to_cell layout sel in
              (pos_dest, Pos.gen_bf_move pos pos_dest @+ ~~[ Bf.Code.Put ])
          | Get sel ->
              let pos_dest = Pos.from_sel_to_cell layout sel in
              (pos_dest, Pos.gen_bf_move pos pos_dest @+ ~~[ Bf.Code.Get ])
          | Loop (sel, code) ->
              let pos_cond = Pos.from_sel_to_cell layout sel in
              let bf_move1 = Pos.gen_bf_move pos pos_cond in
              let pos, bf_loop = gen_bf pos_cond code in
              let bf_move2 = Pos.gen_bf_move pos pos_cond in
              (pos_cond, bf_move1 @+ ~~[ Bf.Code.Loop (bf_loop @+ bf_move2) ])
          | IndexLoop params ->
              gen_bf pos (Code.extend_IndexLoop params)
          | IndexIf params ->
              gen_bf pos (Code.extend_IndexIf params)
          | Shift { n; index; followers } -> begin
              let idx_id = snd index in
              let pos_ptr =
                  Sel.concat_member_to_index_tail index idx_id 0
                  |> Pos.from_sel_to_cell layout
              and pos_ptr_prev =
                Sel.concat_member_to_index_tail index idx_id (-1)
                |> Pos.from_sel_to_cell layout
              in
              let pos, bf_shift_followers =
                gen_bf pos (Code.shift_followers n index followers)
              in
              match n with
              | 0 -> (pos, ~~[])
              | 1 ->
                  let bf_move = Pos.gen_bf_move pos pos_ptr in
                  let bf =
                    bf_shift_followers @+ bf_move @+ ~~[ Bf.Code.Add 1 ]
                  in
                  (pos_ptr_prev, bf)
              | -1 ->
                  let bf_move = Pos.gen_bf_move pos pos_ptr_prev in
                  let bf =
                    bf_shift_followers @+ bf_move @+ ~~[ Bf.Code.Add (-1) ]
                  in
                  (pos_ptr, bf)
              | _ -> failwith "not implemented"
            end
          | If (cond, code_then, code_else) ->
              let ifable = Pos.from_sel_to_ifable layout cond in
              let pos_then_end, bf_then = gen_bf ifable.pos_else code_then in
              let pos_else_end, bf_else = gen_bf ifable.pos_else code_else in
              let bf =
                Pos.gen_bf_move pos ifable.pos_else @+
                ~~[ Bf.Code.Add 1;
                  Bf.Code.Shift (-ifable.cond_to_else);
                  Bf.Code.Loop (
                    ~~[ Bf.Code.Shift ifable.cond_to_else;
                      Bf.Code.Add (-1);
                    ] @+
                    bf_then @+
                    Pos.gen_bf_move pos_then_end ifable.pos_prev_endif
                  );
                  Bf.Code.Shift ifable.cond_to_else;
                  Bf.Code.Loop (
                    ~~[ Bf.Code.Add (-1) ] @+
                    bf_else @+
                    Pos.gen_bf_move pos_else_end ifable.pos_endif
                  );
                ]
              in
              (ifable.pos_endif, bf)
          | Reset sel ->
              [ Code.Loop
                (sel, [ Code.Add (-1, sel) ] |> Code.from_cmds)
              ] |> Code.from_cmds
              |> gen_bf pos
        )
        pos_init
        code
    in
    (pos,
    bf_code_llist |> LList.concat)
  in
  let _, bf = gen_bf Pos.init code in
  bf