open Format

type 'a context = {
  field: Field.main;
  code: 'a Code.t;
  chan: out_channel;
  dump: bool;
}

(* 生存セル解析による最適化 *)
let merge_cells ctx =
  let code = Code.convert_idioms ctx.code in
  let liveness = Liveness.analyze ctx.field code in
  let graph = Liveness.Graph.create ctx.field liveness in
  let field, code =
    Liveness.Graph.create_program_with_merged_cells graph ctx.field code
  in
  if ctx.dump then begin
    let ppf = formatter_of_out_channel ctx.chan in
    fprintf ppf "@[<v>[LIVENESS]@,";
    Liveness.output_analysis_result ppf liveness;
    fprintf ppf "@,@,@[<hov>";
    Liveness.Graph.output_dot ppf graph;
    fprintf ppf "@]@,@]@.";
  end;
  { ctx with field; code; }

(* 条件セルがゼロになるループの除去 *)
let eliminate_never_entered_loop ctx =
  let result = Const.analyze ctx.field ctx.code in
  let code = Const.eliminate_never_entered_loop result in
  if ctx.dump then begin
    let ppf = formatter_of_out_channel ctx.chan in
    fprintf ppf "@[<v>[POSSIBLE CELL VALUES]@,";
    Const.output_analysis_result ppf result;
    fprintf ppf "@,@]@.";
  end;
  { ctx with code }


let codegen ctx =
  let mcounter =
    MovementCounter.from_code ctx.code
    (* MovementCounter.empty () *)
  in
  let layout = Layout.create mcounter ctx.field in
  let bf_code = BfGen.gen_bf layout ctx.code in
  (* Ir.MovementCounter.dump mcounter;
  print_newline (); *)
  (layout, bf_code)

let optimize_full ctx =
  ctx
  |> merge_cells
  |> eliminate_never_entered_loop
  |> codegen

let optimize_without_const ctx =
  ctx
  |> merge_cells
  |> codegen


let max_level = 2
let codegen_by_level = function
  | 0 -> codegen
  | 1 -> optimize_without_const
  | _ -> optimize_full