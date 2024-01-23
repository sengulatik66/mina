(*
 * This file has been generated by the OCamlClientCodegen generator for openapi-generator.
 *
 * Generated by: https://openapi-generator.tech
 *
 * Schema Events_blocks_response.t : EventsBlocksResponse contains an ordered collection of BlockEvents and the max retrievable sequence.
 *)

type t =
  { (* max_sequence is the maximum available sequence number to fetch. *)
    max_sequence : int64
  ; (* events is an array of BlockEvents indicating the order to add and remove blocks to maintain a canonical view of blockchain state. Lightweight clients can use this event stream to update state without implementing their own block syncing logic. *)
    events : Block_event.t list
  }
[@@deriving yojson { strict = false }, show, eq]

(** EventsBlocksResponse contains an ordered collection of BlockEvents and the max retrievable sequence. *)
let create (max_sequence : int64) (events : Block_event.t list) : t =
  { max_sequence; events }
