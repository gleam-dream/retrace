import { resolve } from "node:path";
export default {
  define: { __RETRACE_BUILD__: JSON.stringify("membership-screen-v2-dev") },
  server: { fs: { allow: [resolve("../../..")] } },
};
