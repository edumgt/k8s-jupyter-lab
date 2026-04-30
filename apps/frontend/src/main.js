import { createApp } from "vue";
import { Notify, Quasar } from "quasar";
import iconSet from "quasar/icon-set/material-icons";
import lang from "quasar/lang/en-US";

import "@quasar/extras/material-icons/material-icons.css";
import "ag-grid-community/styles/ag-grid.css";
import "ag-grid-community/styles/ag-theme-quartz.css";
import "quasar/src/css/index.sass";
import "./styles/app.scss";
import App from "./App.vue";

createApp(App)
  .use(Quasar, {
    plugins: { Notify },
    iconSet,
    lang,
  })
  .mount("#app");
