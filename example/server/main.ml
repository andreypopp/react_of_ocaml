[@@@warning "-32"]

open! ContainersLabels
open! Monomorphic
open Lwt.Infix

module UI = struct
  open React_server
  open React

  let markdown children =
    let doc = Omd.of_string (String.trim children) in
    jsx.div ~dangerouslySetInnerHTML:{ __html = Omd.to_html doc }

  let%async_component card ~delay ~title children =
    Lwt_unix.sleep delay >|= fun () ->
    jsx.div ~className:"ba pa2"
      [|
        jsx.h3 ~className:"ma0 pa0 pb2" [| text title |];
        jsx.div ~className:"pb2" children;
        jsx.div ~className:"f7 bt pa1"
          [|
            textf "I've been sleeping for %0.1fsec before appearing."
              delay;
          |];
      |]

  let%component page ~title children =
    jsx.html ~className:"h-100"
      [|
        jsx.head [| jsx.title [| text title |] |];
        jsx.body
          ~className:"pa4 sans-serif dark-gray bg-washed-yellow h-100"
          [| jsx.h1 [| jsx.span [| text title |] |]; jsx.div children |];
      |]

  let intro =
    markdown
      {|
# HELLO

THis is react for ocaml or ocaml for react... The idea is that we produce a app
server in OCmal which can render react apps natively, with speed... yeah...

<b>aaa</b><a href="/">aaa</a>
  |}

  let xapp _req = page ~title:"React componn" [||]

  let app _req =
    page ~title:"React of OCaml"
      [|
        jsx.div ~className:"flex flex-column g2 measure-wide"
          [|
            intro;
            markdown
              {|
            # HELLO

            This is markdown baby...
            |};
            Example_native.Example.App.make
              {
                title = "Hello from Client Component";
                children =
                  text "As you can see, this one is SSR'ed as well.";
              };
            card ~title:"Initial Data" ~delay:0.
              [|
                text
                  "This components loads some async data but will block \
                   the shell until this data is ready.";
              |];
            suspense
              [|
                card ~title:"Async Data" ~delay:1. [| text "HELLO" |];
                card ~title:"Async Data" ~delay:1. [| text "HELLO" |];
              |];
            suspense
              [|
                card ~title:"Async Data" ~delay:2. [| text "OUTER" |];
                suspense
                  [|
                    card ~title:"Inner Async Data" ~delay:1.
                      [| text "INNER" |];
                  |];
              |];
            jsx.div
              [|
                jsx.h2 [| text "Testing XSS" |];
                jsx.ul
                  [|
                    jsx.li
                      [|
                        text "</script><script>console.log(1)</script>";
                      |];
                    jsx.li
                      [| text "\u{2028}<script>console.log(1)</script>" |];
                  |];
              |];
          |];
      |]
end

let () =
  let static =
    Static.Sites.static
    |> List.head_opt
    |> Option.get_exn_or "no /static dir found"
  in
  let links = [ "/static/bundle.css" ] in
  let scripts = [ "/static/bundle.js" ] in
  Dream.run
  @@ Dream.logger
  @@ Dream.router
       [
         Dream.get "/static/**" (Dream.static static);
         Dream.get "/" (React_dream.render ~links ~scripts UI.app);
         Dream.get "/no-ssr"
           (React_dream.render ~enable_ssr:false ~links ~scripts UI.app);
       ]