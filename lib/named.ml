open Batteries
open Printf

module Var: sig
  type t

  val gen: unit -> t
  val gen_named: string -> t
  val to_string: t -> string
end = struct
  type t = int
  let num = ref 0
  let nametable = Hashtbl.create 30
  let gen (): t =
    incr num;
    !num
  let gen_named (name: string): t =
    let id = gen () in
    Hashtbl.add nametable id name;
    id
  let to_string (t: t) =
    match Hashtbl.find_option nametable t with
    | None -> "$" ^ string_of_int t
    | Some name -> "$" ^ name

end


module Dfn = struct
  type t = (Var.t * kind) list
  and kind =
    | Cell
    | CellIfable
    | Lst of lst
    | Ptr
  and lst = {
    length: int option;
    mem: t;
  }

  let of_list t: (Var.t * kind) list = t
  let to_list (t: t): (Var.t * kind) list = t

  let partition_ptr (t: t): Var.t list * t =
    List.partition_map (fun (v, kind) ->
      match kind with
      | Ptr -> Left v
      | kind -> Right (v, kind)
    ) t  
  let partition_inf_lst (t: t): (Var.t * lst) list * t =
    List.partition_map (fun (v, kind) ->
      match kind with
      | Lst ({ length = None; _ } as lst) -> Left (v, lst)
      | kind -> Right (v, kind)
    ) t
  
end


module Sel = struct
  type t =
    | Cell of Var.t
    | Lst of Var.t * int * t
    | LstPtr of Var.t * Var.t * int * t
  
  (* Cmd.Shift用 リストへのセレクタとポインタ名からポインタへのセレクタを得る *)
  let rec ptr_for_shift lst ptr index =
    match lst with
    | Cell lst -> LstPtr (lst, ptr, index, Cell ptr)
    | Lst (v, i, lst) -> Lst (v, i, ptr_for_shift lst ptr index)
    | LstPtr (v, p, i, lst) -> LstPtr (v, p, i, ptr_for_shift lst ptr index)
end


module Layout = struct
  type t = (Var.t * loc) list
  and loc = {
    offset: int;
    kind: kind
  }
  and kind =
    | Ptr
    | Cell
    | CellIfable
    | Lst of lst
  and lst = {
    mem: t;
    header_start: int;
    elm_size: int;
  }

  (* 定義された変数をセルに割り当てる *)
  let of_dfn (dfn: Dfn.t): t =
    let dfn_inf_lst, dfn = Dfn.partition_inf_lst dfn in
    assert (List.length dfn_inf_lst = 0);
    let rec allocate (ofs_available: int) (dfn: Dfn.t) =
      (* 左から詰める *)
      List.fold_left (fun (layout, ofs_available) (var, kind) ->
        let loc, ofs_available =
          match kind with
          | Dfn.Cell -> ({offset = ofs_available; kind = Cell}, ofs_available + 1)
          | CellIfable -> failwith "not implemented"
          | Lst {mem; length = Some length} ->
              let ptrs, mem = Dfn.partition_ptr mem in
              (* メンバを左から詰める *)
              let mem, ptr_ofs_start = allocate 0 mem in
              let header_start =  -ptr_ofs_start in
              (* ポインタを詰める *)
              let mem, elm_size =
                List.fold_left (fun (mem, lst_ofs_available) ptr ->
                  ((ptr, { offset = lst_ofs_available; kind = Ptr }) :: mem, lst_ofs_available + 1)
                ) (mem, ptr_ofs_start) ptrs
              in
              let lst = { mem; header_start; elm_size } in
              ( {offset = ofs_available; kind = Lst lst},
                ofs_available + elm_size*(length + 1) + header_start )
          | Lst { length = None; _} -> assert false
          | Ptr -> assert false
        in
        ((var, loc) :: layout, ofs_available)
      ) ([], ofs_available) dfn
    in
    let layout, _ = allocate 0 dfn in
    layout
  
  let loc_of_var (layout: t) (v: Var.t) = List.assoc v layout

  let rec print ?(d=0) t =
    let indent = String.repeat "      " d in
    List.iter (fun (var, { offset; kind }) ->
      printf "%s%s:\n" indent (Var.to_string var);
      printf "%s  offset: %d\n" indent offset;
      printf "%s  kind: " indent;
      match kind with
      | Cell -> printf "Cell\n"
      | Ptr -> printf "Ptr\n"
      | CellIfable -> printf "Cell(if-able)\n"
      | Lst { mem; header_start; elm_size } ->
          printf "Lst {\n";
          printf "%s    header_start: %d\n" indent header_start;
          printf "%s    elm_size: %d\n" indent elm_size;
          printf "%s    mem:\n" indent;
          print ~d:(d+1) mem;
          printf "%s  }\n" indent
    ) t;
    flush stdout
end


module Pos = struct
  type t =
    | Cell of int
    | Ptr of ptr
  and ptr = {
    offset_of_head: int;
    offset_in_lst: int;
    size: int;
    child_pos: t;
  }

  let init = Cell 0

  let shift n = function
    | Cell offset -> Cell (offset + n)
    | Ptr ({ offset_of_head; _ } as ptr) -> Ptr { ptr with offset_of_head = offset_of_head + n; }

  let rec of_sel (layout: Layout.t) (sel: Sel.t) =
    match sel with
    | Sel.Cell cell ->
        let loc = Layout.loc_of_var layout cell in
        Cell loc.offset
    | Sel.Lst (lst, i, sel) ->
        let loc = Layout.loc_of_var layout lst in
        let mem, header_start, elm_size =
          match loc.kind with
          | Layout.Lst { mem; header_start; elm_size; _ } ->
              (mem, header_start, elm_size)
          | _ -> assert false
        in
        let offset = loc.offset + header_start + (1 + i) * elm_size in
        of_sel mem sel |> shift offset
    | Sel.LstPtr (lst, ptr, i, sel) ->
        let loc = Layout.loc_of_var layout lst in
        let lst =
          match loc.kind with
          | Layout.Lst lst -> lst
          | _ -> assert false
        in
        let ptr_offset_in_lst =
          match Layout.loc_of_var lst.mem ptr with
          | { offset; kind = Ptr } -> offset
          | _ -> assert false
        in
        let index = i * lst.elm_size in
        let child_pos = of_sel lst.mem sel |> shift index in 
        Ptr {
          offset_of_head = loc.offset + lst.header_start + ptr_offset_in_lst;
          offset_in_lst = ptr_offset_in_lst;
          size = lst.elm_size;
          child_pos;
        }
        
  (* リストのポインタを遡って根本のoffset_of_headまで戻るコードを生成する *)
  let rec codegen_root { offset_in_lst; size; child_pos; _ }: Bf.Cmd.t list =
    let origin_offset = match child_pos with
      | Cell offset -> offset
      | Ptr { offset_of_head; _ } -> offset_of_head
    in
    let code = [
      Bf.Cmd.Move (offset_in_lst - origin_offset - size);
      Bf.Cmd.Loop [
        Bf.Cmd.Move (-size)
      ]
    ] in
    match child_pos with
    | Cell _ -> code
    | Ptr ptr -> codegen_root ptr @ code
  (* codegen_move origin dest *)
  let rec codegen_move (origin: t) (dest: t): Bf.Cmd.t list =
    match origin, dest with
    | Ptr origin, Ptr dest when origin.offset_of_head = dest.offset_of_head ->
        codegen_move origin.child_pos dest.child_pos
    | Ptr origin, dest ->
        codegen_root origin @ codegen_move (Cell origin.offset_of_head) dest
    | Cell origin, Ptr dest ->
        let code = [
          Bf.Cmd.Move (dest.offset_of_head + dest.size - origin);
          Bf.Cmd.Loop [
            Bf.Cmd.Move dest.size
          ]
        ] in
        code @ codegen_move (Cell dest.offset_in_lst) (dest.child_pos)
    | Cell origin, Cell dest -> [ Bf.Cmd.Move (dest - origin) ]
end


module Cmd = struct
  type t = 
    | Add of int * Sel.t
    | Put of Sel.t
    | Get of Sel.t
    | Loop of Sel.t * t_list
    | LoopPtr of (Sel.t * Var.t * t_list)
    | Shift of int * Sel.t * Var.t
    | Comment of string
    | Dump
  and t_list = t list
end

let codegen (layout: Layout.t) (cmd_list: Cmd.t_list): Bf.Cmd.t list =
  let rec codegen (pos_init: Pos.t) (cmd_list: Cmd.t_list) =
    let pos, bf_cmd_list_list = List.fold_left_map (fun pos cmd ->
        match cmd with
        | Cmd.Add (n, sel) ->
            let pos_dest = Pos.of_sel layout sel in
            (pos_dest, Pos.codegen_move pos pos_dest @ [ Bf.Cmd.Add n ])
        | Put sel ->
            let pos_dest = Pos.of_sel layout sel in
            (pos_dest, Pos.codegen_move pos pos_dest @ [ Bf.Cmd.Put ])
        | Get sel ->
            let pos_dest = Pos.of_sel layout sel in
            (pos_dest, Pos.codegen_move pos pos_dest @ [ Bf.Cmd.Get ])
        | Loop (sel, cmd_list) ->
            let pos_cond = Pos.of_sel layout sel in
            let code_move1 = Pos.codegen_move pos pos_cond in
            let pos, code_loop = codegen pos_cond cmd_list in
            let code_move2 = Pos.codegen_move pos pos_cond in
            (pos_cond, code_move1 @ [ Bf.Cmd.Loop (code_loop @ code_move2) ])
        | LoopPtr (lst, ptr, cmd_list) ->
            let sel_cond = Sel.ptr_for_shift lst ptr (-1) in
            codegen pos [ Cmd.Loop (sel_cond, cmd_list) ]
        | Shift (n, lst, p) -> begin
            (* let pos_ptr = Pos.of_sel layout sel in
            let pos_ptr_prev = Pos.shift (-layout_lst.elm_size) pos_ptr in *)
            let pos_ptr = Sel.ptr_for_shift lst p 0 |> Pos.of_sel layout in
            let pos_ptr_prev = Sel.ptr_for_shift lst p (-1) |> Pos.of_sel layout in
            match n with
            | 0 -> (pos, [])
            | 1 ->
                let code_move = Pos.codegen_move pos pos_ptr in
                let code = code_move @ [ Bf.Cmd.Add 1 ] in
                (pos_ptr_prev, code)
            | -1 ->
                let code_move = Pos.codegen_move pos pos_ptr_prev in
                let code = code_move @ [ Bf.Cmd.Add (-1) ] in
                (pos_ptr, code)
            | _ -> failwith "not implemented"
          end
        | Comment s -> (pos, [ Bf.Cmd.Comment s ])
        | Dump -> (pos, [ Bf.Cmd.Dump ])
      ) pos_init cmd_list
    in
    (pos, List.flatten bf_cmd_list_list)
  in
  let _, code = codegen Pos.init cmd_list in
  code


module Test = struct
  let a = Var.gen_named "a"
  let b = Var.gen_named "b"
  let x = Var.gen_named "x"
  let y = Var.gen_named "y"
  let z = Var.gen_named "z"
  let p = Var.gen_named "p"
  let p1 = Var.gen_named "p1"
  let p2 = Var.gen_named "p2"
  let c = Var.gen_named "c"
  let test =
    let dfn =
      let open Dfn in [
        (a, Cell);
        (b, Lst {
          length = Some 3;
          mem = [
            (x, Cell);
            (y, Lst {
              length = Some 2;
              mem = [
                (p, Ptr);
                (z, Cell);
              ]
            });
            (p1, Ptr); (p2, Ptr)
          ];
        });
        (c, Cell);
      ]
    in
    let layout = Layout.of_dfn dfn in
    (dfn, layout)
  
  let dfn, layout = test
end