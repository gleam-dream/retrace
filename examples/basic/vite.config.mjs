import { resolve } from "node:path";
export default {
  plugins: [
    {
      name: "browser-only-consumer",
      resolveId(source) {
        if (source.startsWith("@tauri-apps/"))
          throw Error("Browser consumer must not require native dependencies");
      },
    },
  ],
  server: { fs: { allow: [resolve("../..")] } },
  build: {
    rollupOptions: {
      input: {
        app: resolve("index.html"),
        viewer: resolve("viewer.html"),
        frame: resolve("frame.html"),
      },
    },
  },
};
