open Support.Pervasive
open Support.Info
open Syntax
open Value

(* ソースコードを読み込むときは必ずこれを通すこと
   失敗した場合は例外を投げる。
   Lexerのエラー、Parserのエラーの2通りがある。
   TODO: 例外を投げないようにしたい。それはimportの位置情報をエラーに含めたいから。
*)
let load filename channel =
  let lexbuf = Lexer.create filename channel in
  match Parser.program Lexer.main lexbuf with
  | program ->
      SyntaxScan.scan_program ~pname:None program;
      program
  | exception Parser.Error ->
      let info = !Lexer.curr_info |> Option.get in
      Error.top info Parser_Unexpected
  (* | exception Sys_error reason ->
      let info = create_info_only_filename filename in
      Error.top info
        @@ File_Failed_to_read { reason } *)

(** in_channelではなくファイル名を渡すとloadしてくれる便利なやつ *)
let load_from_source path =
  let channel = open_in path in
  Fun.protect (fun () -> load path channel)
    ~finally:(fun () -> close_in channel)

let lib_path =
  [ Sys.getenv_opt "BFML_LIB_PATH";
    Sys.getenv_opt "DUNE_SOURCEROOT"
      |> Option.map (fun r -> Filename.concat r "examples/lib");
    Sys.getenv_opt "OPAM_SWITCH_PREFIX"
      |> Option.map (fun r -> Filename.concat r "share/reusable-bf/lib");
  ]
  |> List.find_map Fun.id

(** 相対パスまたは絶対パスからファイルを探し、
    存在すればカレントディレクトリからのパスまたは絶対パスを返す *)
let find_source base_dir path =
  let exception R of Error.t in
  try
    let paths =
      if not (Filename.is_relative path) then [path]
      else
        [ lib_path ]
        |> List.filter_map Fun.id
        |> List.cons base_dir
        |> List.map (fun dir -> Filename.concat dir path)
    in
    let found_path = List.find_opt Sys.file_exists paths in
    match found_path with
    | Some p ->
        if Sys.is_directory p then
          raise @@ R (Module_import_file_is_directory path);
        Ok (FilePath.reduce p)  (* 余分な ./ は一応消しておく *)
    | None -> raise @@ R (Module_import_file_not_found path)
  with R e -> Error e


module FileMap = struct
  (* カレントディレクトリからのパスをキーとするマップ
     realpathが同一なら同一ファイル扱いする
     読み込んだファイルの評価結果をキャッシュするほか、循環参照の検出も行う
  *)

  module M = Map.Make(struct
    type t = string
    let compare = compare
  end)

  type progress = Loading | Loaded of envs
  type t = progress M.t

  let realpath path =
    match Sys.backend_type with
    | Other "js_of_ocaml" ->
        (* js_of_ocaml のときファイル名が同じだったら同じファイル扱い *)
        Filename.basename path
    | _ -> Unix.realpath path
    
  let empty : t = M.empty

  let add path v (m: t) =
    let key = realpath path in
    M.update key
      (function
        | None | Some Loading -> Some v
        | Some (Loaded _) -> assert false
      ) m

  let find path (m: t) =
    let key = realpath path in
    M.find_opt key m
end


type ctx =
  { envs: envs;
    ex_envs: envs; (* エクスポートされる環境 *)
    base_dirname: string;
    filemap: FileMap.t;
  }

let rec eval_decl ctx decl : ctx =
  (* print_endline ctx.base_dirname;
  VE.to_seq ctx.ex_envs.va_env |> Seq.map fst |> Seq.map Var.to_string
  |> List.of_seq
  |> String.concat ", " |> print_endline; *)
  match decl.v with
  | DeclExpr expr ->
      Eval.eval ~recn:0 ctx.envs expr |> Va.to_unit empty_trace expr.i;
      ctx
  | DeclLet { binding; is_priv } ->
      let env = Eval.eval_let_binding ~recn:0 ctx.envs binding in
      { ctx with
        envs = Envs.extend_with_value_env env ctx.envs;
        ex_envs = if is_priv
          then ctx.ex_envs
          else Envs.extend_with_value_env env ctx.ex_envs;
      }
  | DeclLetRec { binding=(v, ex); is_priv } ->
      let env = Eval.eval_let_rec ~recn:0 ctx.envs v ex in
      { ctx with
        envs = Envs.extend_with_value_env env ctx.envs;
        ex_envs = if is_priv
          then ctx.ex_envs
          else Envs.extend_with_value_env env ctx.ex_envs;
      }
  | DeclOpen mod_ex ->
      let ctx, mod_envs = eval_mod_expr ctx mod_ex in
      { ctx with envs = Envs.import mod_envs ctx.envs }
  | DeclInclude mod_ex ->
      (* 封印中 *)
      let ctx, mod_envs = eval_mod_expr ctx mod_ex in
      { ctx with
        envs = Envs.import mod_envs ctx.envs;
        ex_envs = Envs.import mod_envs ctx.ex_envs;
      }
  | DeclModule { binding=(uv, mod_ex); is_priv } ->
      let ctx, mod_envs = eval_mod_expr ctx mod_ex in
      { ctx with
        envs = Envs.add_module_binding uv mod_envs ctx.envs;
        ex_envs = if is_priv
          then ctx.ex_envs
          else Envs.add_module_binding uv mod_envs ctx.ex_envs;
      }

and eval_decls ctx decls : ctx =
  List.fold_left eval_decl ctx decls

and eval_mod_expr ctx mod_expr =
  match mod_expr.v with
  | ModImport p -> begin
      let path =
        match find_source ctx.base_dirname p with
        | Ok p -> p
        | Error e -> Error.top mod_expr.i e
      in
      match FileMap.find path ctx.filemap with
      | Some Loading -> Error.top mod_expr.i Module_Recursive_import
      | Some (Loaded envs) -> (ctx, envs)
      | None ->
          let ctx' = {
            envs = Envs.initial;
            ex_envs = Envs.empty;
            base_dirname = Filename.dirname path;
            filemap = FileMap.add path Loading ctx.filemap;
          } in
          let prog = load_from_source path in
          let ctx' = eval_decls ctx' prog in
          let envs = ctx'.ex_envs in
          let filemap = FileMap.add path (Loaded envs) ctx'.filemap in
          ({ ctx with filemap }, envs)
    end
  | ModStruct prog ->
      let ctx' = {
        ctx with
        ex_envs = Envs.empty;
      } in
      let ctx' = eval_decls ctx' prog in
      ({ ctx with filemap = ctx'.filemap }, ctx'.ex_envs)
  | ModVar l -> begin
      assert (l <> []);
      let envs =
        List.fold_left
          (fun envs u ->
            match UVE.lookup u envs.module_env with
            | None -> Error.top mod_expr.i (Eval_Module_not_defined u)
            | Some envs -> envs
          ) ctx.envs l
      in
      (ctx, envs)
    end

let gen_ir (dirname: string) (program: program)
    : Ir.Field.main * 'a Ir.Code.t =
  let ctx = {
    envs = Envs.initial;
    ex_envs = Envs.empty;
    base_dirname = dirname;
    filemap = FileMap.empty;
  } in
  let ctx = eval_decls ctx program in
  match VE.lookup (Var.of_string "main") ctx.ex_envs.va_env with
  | None -> Error.unknown Top_Missing_main
  | Some (VaBlock (envs, stmts)) -> IrGen.generate envs stmts
  | Some _ -> Error.unknown Top_main_is_not_stmts
;;

(** ファイルを読んでbfに変換する
    エラーハンドリングが雑なので開発用 *)
let gen_bf_from_source ?(opt_level=Ir.Opt.max_level) path =
  let dirname = Filename.dirname path in
  let program = load_from_source path in
  let field, ir_code = gen_ir dirname program in
  let opt_context =
    Ir.Opt.{ field; code=ir_code; chan=stderr; dump=false }
  in
  let _, bf_code =
    Ir.Opt.codegen_by_level opt_level opt_context
  in
  bf_code