import { setWorldConstructor, World } from "@cucumber/cucumber";

export class DevcontainerBuilderWorld extends World {
  constructor(options) {
    super(options);
    this.response = undefined;
  }
}

setWorldConstructor(DevcontainerBuilderWorld);
