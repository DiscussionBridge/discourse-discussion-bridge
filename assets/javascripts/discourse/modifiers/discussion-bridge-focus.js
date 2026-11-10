import { modifier } from "ember-modifier";

export function revealAndFocus(element) {
  element?.focus({ preventScroll: true });
  element?.scrollIntoView({ block: "start" });
}

export default modifier((element, [requested]) => {
  if (requested) {
    revealAndFocus(element);
  }
});
