#let zds-number = "XXXXX"
#let zds-title = "Title Goes Here"
#let zds-state = "prediscussion"
#let zds-created = "YYYY-MM-DD"
#let zds-discussion = "Draft discussion note"
#let zds-labels = ("documentation", "engineering",)
#let zds-authors = ("Your Name <you@insan.ai>",)
#let zds-category = "Engineering Discussion"
#let zds-status = "Internal Draft"
#let zds-last-updated = "None"

#import "../../shared/zds.typ": zds-document

#show: doc => zds-document(
  zds-number,
  zds-title,
  doc,
  authors: zds-authors,
  state: zds-state,
  created: zds-created,
  discussion: zds-discussion,
  labels: zds-labels,
  category: zds-category,
  status: zds-status,
  last-updated: zds-last-updated,
)

= Abstract

State the problem, the proposed direction, and the reason this document exists.

= Introduction

Provide the background and the constraints that make the topic worth discussing now.

= Terminology and Scope

Define the terms used in the document and state what is in scope versus explicitly out of scope.

= Problem Statement

Describe the gap in the current system, workflow, or design.

= Goals and Non-Goals

== Goals

- List the properties the proposal must satisfy.

== Non-Goals

- List adjacent problems that this document does not solve.

= Design Overview

Explain the high-level proposal in a way that lets the reader understand the rest of the document.

= Detailed Design

Break the design into the main mechanisms, data flows, interfaces, or document structures.

= Security Considerations

Discuss risks that the design introduces or affects.

= Operational Considerations

Document runtime, rollout, maintenance, or contributor workflow implications.

= Alternatives Considered

List the main rejected options and why they were rejected.

= Open Questions

Capture unresolved questions that must be answered before the document can move to active discussion or publication.

= References

- Add links to related ZDS documents, code, issues, or external references.
