import { transform } from "sucrase";

globalThis.__tetoCompileTypescript = function (source) {
  return transform(String(source || ""), {
    transforms: ["typescript"],
    disableESTransforms: true,
    preserveDynamicImport: true,
  }).code;
};
