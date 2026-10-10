import("/build/dev/javascript/retrace_example/retrace_example.mjs")
  .then(({ main }) => main())
  .catch((error) => {
    const message = document.createElement("p");
    message.setAttribute("role", "alert");
    message.textContent = `The example could not start: ${error.message}`;
    document.querySelector("#app").replaceChildren(message);
    console.error(error);
  });
