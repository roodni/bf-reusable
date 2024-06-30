# bf-reusable

brainfuckに変換されるプログラミング言語です。
- 抽象化されたポインタ操作
- brainfuckに近い命令セット
- ML風のメタプログラミング機構

## 例

[Playgroundで試せます](https://roodni.github.io/bf-reusable-playground-frontend/)

```
// Hello World!

// 文字列を引数に取り、それを出力する命令列を返す
let gen_puts s = [
  $alloc { c }
  **let len = string_length s in
    let rec loop i prev =
      if i < len then
        let curr = string_get s i in
        [
          + c (curr - prev)
          . c
          *loop (i + 1) curr
        ]
      else []
    in
    loop 0 0
]

let main = gen_puts "Hello World!\n"
```

## インストール

### 準備
1. [opam](https://opam.ocaml.org/) をインストールする
2. opamで ocaml (>= 4.14) をインストールする

### ビルド
```sh
git clone https://github.com/roodni/bf-reusable
cd bf-reusable
opam install .
```

## 実行

* コンパイルする `bfml file.bfml`
* コンパイルして実行する `bfml -r file.bfml`
* brainfuckのプログラムを実行する `bfml -b file.b`

### サンプルプログラムの実行例

* `examples/hello.bfml`: Hello World!
  ```sh
  bfml -r examples/hello.bfml
  ```

* `examples/bfi.bfml`: brainfuckインタプリタ
  ```sh
  mkdir _sandbox
  cd _sandbox
  bfml ../examples/bfi.bfml > bfi.b
  bfml ../examples/hello.bfml > hello.b

  # hello.b を実行する
  echo '\' >> hello.b
  bfml -b bfi.b < hello.b

  # 自分自身を実行して hello.b を入力に与える
  cp bfi.b input.txt
  echo '\' >> input.txt
  cat hello.b >> input.txt
  bfml -b bfi.b < input.txt
  ```

## 資料
* ドキュメントは準備中です
* 解説スライド https://www.slideshare.net/roodni/brainfuckbfreusable
  * 情報が古いです
  * 現状とは構文がだいぶ違います

<!--
### 負のセルに関する注意
bf-reusableは`$alloc`で確保されたセルに対して以下の操作
* ゼロ初期化 (`[-]`)
* ムーブ (`[->>+<<]` など)

を必要に応じて自動挿入します。

これらの操作は、処理系によっては、セルの中身が負である場合にエラーや無限ループを引き起こす可能性があります。以下の事項に留意することで、セルの中身が一時的に負になるようなプログラムを動作させられます。
* `$alloc`のスコープの終わりの時点でセルの中身を非負にする。
* インデックスシフト文 (`> a@i` `< a@i`) の時点でセルの中身を非負にする。

```
(* 例 *)
$alloc { x }

, x
- x 'A'

? x
  [ (* 入力された文字は A でない *) ]
  [ (* 入力された文字は A である *) ]

+ x 'A'  (* 非負になるように足す *)
```

-->