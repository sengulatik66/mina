(** Test that wire types and original types can be used interchangeably in the
    eyes of the type system. *)

[@@@warning "-34"]

module type S0 = sig
  type t
end

module WT = Mina_wire_types

(* Given two modules containing one type, check the types are equal *)
module Assert_equal0 (O : S0) (W : S0 with type t = O.t) = struct end

module Currency = struct
  module O = Currency
  module W = WT.Currency
  include Assert_equal0 (O.Fee) (W.Fee)
  include Assert_equal0 (O.Amount) (W.Amount)
  include Assert_equal0 (O.Balance) (W.Balance)
end

module Snark_params = struct
  module O = Snark_params
  module W = WT.Snark_params
  include Assert_equal0 (O.Tick.Field) (W.Tick.Field)
  include Assert_equal0 (O.Tock.Field) (W.Tock.Field)
  include Assert_equal0 (O.Tick.Inner_curve) (W.Tick.Inner_curve)
  include Assert_equal0 (O.Tock.Inner_curve) (W.Tock.Inner_curve)
  include Assert_equal0 (O.Tick.Inner_curve.Scalar) (W.Tick.Inner_curve.Scalar)
  include Assert_equal0 (O.Tock.Inner_curve.Scalar) (W.Tock.Inner_curve.Scalar)
end

module Public_key = struct
  module O = Signature_lib.Public_key
  module W = WT.Public_key
  include Assert_equal0 (O.Compressed) (W.Compressed)
  include Assert_equal0 (O) (W)
end

module Mina_numbers = struct
  module O = Mina_numbers
  module W = WT.Mina_numbers
  include Assert_equal0 (O.Account_nonce) (W.Account_nonce)
  include Assert_equal0 (O.Global_slot) (W.Global_slot)
end

module Mina_base = struct
  module O = Mina_base
  module W = WT.Mina_base
  include
    Assert_equal0
      (O.Signed_command_payload.Common)
      (W.Signed_command_payload.Common)
  include
    Assert_equal0
      (O.Signed_command_payload.Body)
      (W.Signed_command_payload.Body)
  include Assert_equal0 (O.Signed_command_payload) (W.Signed_command_payload)
  include Assert_equal0 (O.Signed_command_memo) (W.Signed_command_memo)
  include Assert_equal0 (O.Signed_command) (W.Signed_command)
  include Assert_equal0 (O.Token_id) (W.Token_id)
  include Assert_equal0 (O.Payment_payload) (W.Payment_payload)
  include Assert_equal0 (O.Stake_delegation) (W.Stake_delegation)
  include Assert_equal0 (O.New_token_payload) (W.New_token_payload)
  include Assert_equal0 (O.New_account_payload) (W.New_account_payload)
  include Assert_equal0 (O.Minting_payload) (W.Minting_payload)
  include Assert_equal0 (O.Signature) (W.Signature)
end
