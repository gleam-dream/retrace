import { Result$Ok, Result$Error } from "./gleam.mjs";

export function checkLabel(reply) {
  fetch("/protected-response.json")
    .then((response) =>
      reply(response.ok ? Result$Ok(undefined) : Result$Error(undefined)),
    )
    .catch(() => reply(Result$Error(undefined)));
}
