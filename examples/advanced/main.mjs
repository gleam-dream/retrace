document.body.dataset.diagnostics = String(
  new URL(location.href).searchParams.has("diagnostics"),
);
import("/build/dev/javascript/retrace_example/retrace_example.mjs")
  .then(({ main }) => {
    const dispose = main();
    window.addEventListener("pagehide", dispose, { once: true });
    if (import.meta.hot) import.meta.hot.dispose(dispose);
  })
  .catch((error) => {
    const message = document.createElement("p");
    message.setAttribute("role", "alert");
    message.textContent = `The example could not start: ${error.message}`;
    document.querySelector("#app").replaceChildren(message);
    console.error(error);
  });

window.addEventListener("pageshow", (event) => {
  if (event.persisted) location.reload();
});
