open StdLabels
open Syntax

exception
  Error of
    { pos : Lexing.position
    ; msg : string
    }

let raisef ~pos fmt = Printf.ksprintf (fun msg -> raise (Error { pos; msg })) fmt

let rec advance_bol s (bol : Lexing.position) ~start ~stop =
  if start >= stop
  then bol
  else (
    match s.[start] with
    | '\n' ->
      advance_bol
        s
        { bol with pos_lnum = bol.pos_lnum + 1; pos_bol = start + 1 }
        ~start:(start + 1)
        ~stop
    | _ -> advance_bol s bol ~start:(start + 1) ~stop)
;;

let rec loop ~copy_input ~syntax ~f ~file_contents ~keep ~text_start ~bol ~pos =
  match Re.exec_opt syntax.comment_start_dollar file_contents ~pos with
  | None -> if keep then copy_input text_start (String.length file_contents - text_start)
  | Some groups ->
    let start = Re.Group.start groups 0 in
    let stop = Re.Group.stop groups 0 in
    (match Re.exec_opt syntax.comment_end_anchored file_contents ~pos:stop with
     | Some groups ->
       let stop = Re.Group.stop groups 0 in
       let start = if keep then text_start else start in
       copy_input start (stop - start);
       let bol = advance_bol file_contents bol ~start:pos ~stop in
       loop
         ~copy_input
         ~syntax
         ~f
         ~file_contents
         ~keep:true
         ~pos:stop
         ~bol
         ~text_start:stop
     | None ->
       let bol = advance_bol file_contents bol ~start:pos ~stop in
       let last_text_block = text_start, start - text_start in
       let start = if keep then text_start else start in
       let code_start = { bol with Lexing.pos_cnum = stop } in
       let code_stop, keep_next, pos =
         code ~copy_input ~syntax ~file_contents ~depth:0 ~pos:stop ~code_start
       in
       let code =
         let code_start = code_start.pos_cnum in
         String.sub file_contents ~pos:code_start ~len:(code_stop - code_start)
       in
       copy_input start (pos - start);
       f ~last_text_block ~code_start ~code;
       let bol = advance_bol file_contents bol ~start:stop ~stop:pos in
       loop
         ~copy_input
         ~syntax
         ~f
         ~file_contents
         ~keep:keep_next
         ~text_start:pos
         ~bol
         ~pos)

and code ~copy_input ~syntax ~file_contents ~depth ~pos ~code_start =
  match
    Re.exec_opt
      syntax.comment_end_or_dollar_comment_end_or_comment_start_if_rec_comment
      file_contents
      ~pos
  with
  | None -> raisef ~pos:code_start "End of file reached before end of code block"
  | Some groups ->
    let start = Re.Group.start groups 0 in
    let stop = Re.Group.stop groups 0 in
    if Re.Group.test groups 3
    then
      (* Group 3 matched --> this is comment_start *)
      code ~copy_input ~syntax ~file_contents ~code_start ~depth:(depth + 1) ~pos:stop
    else if Re.Group.test groups 2
    then
      if (* Group 2 matched --> this is dollar_comment_end *)
        depth = 0
      then start, true, stop
      else
        code ~copy_input ~syntax ~file_contents ~depth:(depth - 1) ~pos:stop ~code_start
    else (
      assert (Re.Group.test groups 1);
      (* Group 1 matched --> this is comment_end *)
      if depth = 0
      then start, false, stop
      else
        code ~copy_input ~syntax ~file_contents ~depth:(depth - 1) ~pos:stop ~code_start)
;;

let run ~syntax ~f ~file_name ~file_contents ~copy_input =
  loop
    ~copy_input
    ~syntax
    ~f
    ~file_contents
    ~keep:true
    ~text_start:0
    ~bol:{ pos_fname = file_name; pos_lnum = 1; pos_bol = 0; pos_cnum = 0 }
    ~pos:0
;;
