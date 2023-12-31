open! Import

type json = Yojson.Basic.t

module React = React_model

let render_to_model = Render_to_model.render

type html_rendering = Render_to_html.html_rendering =
  | Html_rendering_done of { html : Html.t }
  | Html_rendering_async of {
      html_shell : Html.t;
      html_iter : (Html.t -> unit Lwt.t) -> unit Lwt.t;
    }

let render_to_html = Render_to_html.render

module Html = Html

type browser_only
