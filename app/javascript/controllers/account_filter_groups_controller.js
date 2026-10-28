import { Controller } from "@hotwired/stimulus";

// Group checkboxes for the transaction account filter.
//
// Each primary account type (cash, investments, ...) has a checkbox that checks
// or unchecks the accounts of that type. The group checkbox is never submitted:
// only the individual account checkboxes are, so the filter query is unchanged.
//
// While the list is narrowed by the search box, a group checkbox acts on the
// accounts still showing, so "search, then check the group" selects just the
// matches. The group's own state always reflects every account in the group:
// checked when all are, indeterminate when only some are.
export default class extends Controller {
  static targets = ["group", "account"];

  connect() {
    this.groupTargets.forEach((box) => this.#syncGroup(box.dataset.group));
  }

  toggleGroup(event) {
    const box = event.target;

    this.#accountsIn(box.dataset.group)
      .filter((account) => this.#isShown(account))
      .forEach((account) => {
        account.checked = box.checked;
      });

    this.#syncGroup(box.dataset.group);
  }

  syncGroup(event) {
    this.#syncGroup(event.target.dataset.group);
  }

  #accountsIn(group) {
    return this.accountTargets.filter((account) => account.dataset.group === group);
  }

  // The list filter hides a row by setting display on its .filterable-item.
  #isShown(account) {
    const row = account.closest(".filterable-item");
    return !row || row.style.display !== "none";
  }

  #syncGroup(group) {
    const box = this.groupTargets.find((candidate) => candidate.dataset.group === group);
    if (!box) return;

    const accounts = this.#accountsIn(group);
    const checkedCount = accounts.filter((account) => account.checked).length;

    box.checked = accounts.length > 0 && checkedCount === accounts.length;
    box.indeterminate = checkedCount > 0 && checkedCount < accounts.length;
  }
}
