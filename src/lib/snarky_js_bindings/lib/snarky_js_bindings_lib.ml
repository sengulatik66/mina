module Backend = Kimchi_backend.Pasta.Vesta_based_plonk
module Other_backend = Kimchi_backend.Pasta.Pallas_based_plonk

(*
let () = Backend.Keypair.set_urs_info []
   *)

let loose_permissions : Mina_base_kernel.Permissions.t =
  { stake = true
  ; edit_state = None
  ; send = None
  ; receive = None
  ; set_delegate = None
  ; set_permissions = None
  ; set_verification_key = None
  ; set_snapp_uri = None
  ; edit_sequence_state = None
  ; set_token_symbol = None
  }

module Impl = Pickles.Impls.Step

(* module Impl = Snarky_backendless.Snark.Run.Make (Backend) (Core_kernel.Unit) *)

module Other_impl = Pickles.Impls.Wrap

(* module Other_impl = Snarky_backendless.Snark.Run.Make (Other_backend) (Core_kernel.Unit) *)

module Challenge = Limb_vector.Challenge.Make (Impl)
module Sc =
  Pickles.Scalar_challenge.Make (Impl) (Pickles.Step_main_inputs.Inner_curve)
    (Challenge)
    (Pickles.Endo.Step_inner_curve)
module Js = Js_of_ocaml.Js

let console_log_string s = Js_of_ocaml.Firebug.console##log (Js.string s)

let console_log s = Js_of_ocaml.Firebug.console##log s

(*
let () =
  let two = Unsigned.UInt64.of_int 2 in
  let a = Unsigned.UInt64.of_string "18446744073709551615" in
  let cmp =
    Js.Unsafe.eval_string
      {js|(function integers_uint64_compare(x, y) {
    x.hi = x.hi >>> 0;
    y.hi = y.hi >>> 0;
    return x.ucompare(y);
})|js}
  in
  Firebug.console##log two ;
  Firebug.console##log a ;
  Firebug.console##log (Unsigned.UInt64.to_string a |> Js.string) ;
  Firebug.console##log (Unsigned.UInt64.compare two a) ;
  Firebug.console##log Js.Unsafe.(fun_call cmp [| inject two; inject a |])
   *)

let raise_error s =
  let s = Js.string s in
  Js.raise_js_error (new%js Js.error_constr s)

let raise_errorf fmt = Core_kernel.ksprintf raise_error fmt

class type field_class =
  object
    method value : Impl.Field.t Js.prop

    method toString : Js.js_string Js.t Js.meth

    method toJSON : < .. > Js.t Js.meth

    method toFields : field_class Js.t Js.js_array Js.t Js.meth
  end

and bool_class =
  object
    method value : Impl.Boolean.var Js.prop

    method toBoolean : bool Js.t Js.meth

    method toField : field_class Js.t Js.meth

    method toJSON : < .. > Js.t Js.meth

    method toFields : field_class Js.t Js.js_array Js.t Js.meth
  end

module As_field = struct
  (* number | string | boolean | field_class | cvar *)
  type t

  let of_field (x : Impl.Field.t) : t = Obj.magic x

  let of_field_obj (x : field_class Js.t) : t = Obj.magic x

  let value (value : t) : Impl.Field.t =
    match Js.to_string (Js.typeof (Obj.magic value)) with
    | "number" ->
        let value = Js.float_of_number (Obj.magic value) in
        if Float.is_integer value then
          let value = Float.to_int value in
          if value >= 0 then Impl.Field.of_int value
          else Impl.Field.negate (Impl.Field.of_int (-value))
        else raise_error "Cannot convert a float to a field element"
    | "boolean" ->
        let value = Js.to_bool (Obj.magic value) in
        if value then Impl.Field.one else Impl.Field.zero
    | "string" -> (
        let value : Js.js_string Js.t = Obj.magic value in
        let s = Js.to_string value in
        try
          Impl.Field.constant
            ( if
              String.length s >= 2
              && Char.equal s.[0] '0'
              && Char.equal (Char.lowercase_ascii s.[1]) 'x'
            then Kimchi_pasta.Pasta.Fp.(of_bigint (Bigint.of_hex_string s))
            else Impl.Field.Constant.of_string s )
        with Failure e -> raise_error e )
    | "object" ->
        let is_array = Js.to_bool (Js.Unsafe.global ##. Array##isArray value) in
        if is_array then
          (* Cvar case *)
          (* TODO: Check this works *)
          Obj.magic value
        else
          (* Object case *)
          Js.Optdef.get
            (Obj.magic value)##.value
            (fun () -> raise_error "Expected object with property \"value\"")
    | s ->
        raise_error
          (Core_kernel.sprintf
             "Type \"%s\" cannot be converted to a field element" s)

  let field_class : < .. > Js.t =
    let f =
      (* We could construct this using Js.wrap_meth_callback, but that returns a
         function that behaves weirdly (from the point-of-view of JS) when partially applied. *)
      Js.Unsafe.eval_string
        {js|
        (function(asFieldValue) {
          return function(x) {
            this.value = asFieldValue(x);
            return this;
          };
        })
      |js}
    in
    Js.Unsafe.(fun_call f [| inject (Js.wrap_callback value) |])

  let field_constr : (t -> field_class Js.t) Js.constr = Obj.magic field_class

  let to_field_obj (x : t) : field_class Js.t =
    match Js.to_string (Js.typeof (Obj.magic value)) with
    | "object" ->
        let is_array = Js.to_bool (Js.Unsafe.global ##. Array##isArray value) in
        if is_array then (* Cvar case *)
          new%js field_constr x else Obj.magic x
    | _ ->
        new%js field_constr x
end

let field_class = As_field.field_class

let field_constr = As_field.field_constr

open Core_kernel

let bool_constant (b : Impl.Boolean.var) =
  match (b :> Impl.Field.t) with
  | Constant b ->
      Some Impl.Field.Constant.(equal one b)
  | _ ->
      None

module As_bool = struct
  (* boolean | bool_class | Boolean.var *)
  type t

  let of_boolean (x : Impl.Boolean.var) : t = Obj.magic x

  let of_bool_obj (x : bool_class Js.t) : t = Obj.magic x

  let of_js_bool (b : bool Js.t) : t = Obj.magic b

  let value (value : t) : Impl.Boolean.var =
    match Js.to_string (Js.typeof (Obj.magic value)) with
    | "boolean" ->
        let value = Js.to_bool (Obj.magic value) in
        Impl.Boolean.var_of_value value
    | "object" ->
        let is_array = Js.to_bool (Js.Unsafe.global ##. Array##isArray value) in
        if is_array then
          (* Cvar case *)
          (* TODO: Check this works *)
          Obj.magic value
        else
          (* Object case *)
          Js.Optdef.get
            (Obj.magic value)##.value
            (fun () -> raise_error "Expected object with property \"value\"")
    | s ->
        raise_error
          (Core_kernel.sprintf "Type \"%s\" cannot be converted to a boolean" s)
end

let bool_class : < .. > Js.t =
  let f =
    Js.Unsafe.eval_string
      {js|
      (function(asBoolValue) {
        return function(x) {
          this.value = asBoolValue(x);
          return this;
        }
      })
    |js}
  in
  Js.Unsafe.(fun_call f [| inject (Js.wrap_callback As_bool.value) |])

let bool_constr : (As_bool.t -> bool_class Js.t) Js.constr =
  Obj.magic bool_class

(* TODO: Extend prototype for number to allow for field element methods *)

module Field = Impl.Field
module Boolean = Impl.Boolean
module As_prover = Impl.As_prover
module Constraint = Impl.Constraint
module Bigint = Impl.Bigint
module Keypair = Impl.Keypair
module Verification_key = Impl.Verification_key
module Typ = Impl.Typ

let singleton_array (type a) (x : a) : a Js.js_array Js.t =
  let arr = new%js Js.array_empty in
  arr##push x |> ignore ;
  arr

let handle_constants f f_constant (x : Field.t) =
  match x with Constant x -> f_constant x | _ -> f x

let handle_constants2 f f_constant (x : Field.t) (y : Field.t) =
  match (x, y) with Constant x, Constant y -> f_constant x y | _ -> f x y

let array_get_exn xs i =
  Js.Optdef.get (Js.array_get xs i) (fun () ->
      raise_error (sprintf "array_get_exn: index=%d, length=%d" i xs##.length))

let array_check_length xs n =
  if xs##.length <> n then raise_error (sprintf "Expected array of length %d" n)

let method_ class_ (name : string) (f : _ Js.t -> _) =
  let prototype = Js.Unsafe.get class_ (Js.string "prototype") in
  Js.Unsafe.set prototype (Js.string name) (Js.wrap_meth_callback f)

let optdef_arg_method (type a) class_ (name : string)
    (f : _ Js.t -> a Js.Optdef.t -> _) =
  let prototype = Js.Unsafe.get class_ (Js.string "prototype") in
  let meth =
    let wrapper =
      Js.Unsafe.eval_string
        {js|
        (function(f) {
          return function(xOptdef) {
            return f(this, xOptdef);
          };
        })|js}
    in
    Js.Unsafe.(fun_call wrapper [| inject (Js.wrap_callback f) |])
  in
  Js.Unsafe.set prototype (Js.string name) meth

let to_js_field =
  let method_ name (f : field_class Js.t -> _) = method_ field_class name f in
  let to_string (x : Field.t) =
    ( match x with
    | Constant x ->
        x
    | x ->
        (* TODO: Put good error message here. *)
        As_prover.read_var x )
    |> Field.Constant.to_string |> Js.string
  in
  let mk x : field_class Js.t = new%js field_constr (As_field.of_field x) in
  let add_op1 name (f : Field.t -> Field.t) =
    method_ name (fun this : field_class Js.t -> mk (f this##.value))
  in
  let add_op2 name (f : Field.t -> Field.t -> Field.t) =
    method_ name (fun this (y : As_field.t) : field_class Js.t ->
        mk (f this##.value (As_field.value y)))
  in
  let sub =
    handle_constants2 Field.sub (fun x y ->
        Field.constant (Field.Constant.sub x y))
  in
  let div =
    handle_constants2 Field.div (fun x y ->
        Field.constant (Field.Constant.( / ) x y))
  in
  let sqrt =
    handle_constants Field.sqrt (fun x ->
        Field.constant (Field.Constant.sqrt x))
  in
  add_op2 "add" Field.add ;
  add_op2 "sub" sub ;
  add_op2 "div" div ;
  add_op2 "mul" Field.mul ;
  add_op1 "neg" Field.negate ;
  add_op1 "inv" Field.inv ;
  add_op1 "square" Field.square ;
  add_op1 "sqrt" sqrt ;
  method_ "toString" (fun this : Js.js_string Js.t -> to_string this##.value) ;
  method_ "sizeInFields" (fun _this : int -> 1) ;
  method_ "toFields" (fun this : field_class Js.t Js.js_array Js.t ->
      singleton_array this) ;
  ((* TODO: Make this work with arbitrary bit length *)
   let bit_length = Field.size_in_bits - 2 in
   let cmp_method (name, f) =
     method_ name (fun this (y : As_field.t) : unit ->
         f ~bit_length this##.value (As_field.value y))
   in
   let bool_cmp_method (name, f) =
     method_ name (fun this (y : As_field.t) : bool_class Js.t ->
         new%js bool_constr
           (As_bool.of_boolean
              (f (Field.compare ~bit_length this##.value (As_field.value y)))))
   in
   (List.iter ~f:bool_cmp_method)
     [ ("lt", fun { less; _ } -> less)
     ; ("lte", fun { less_or_equal; _ } -> less_or_equal)
     ; ("gt", fun { less_or_equal; _ } -> Boolean.not less_or_equal)
     ; ("gte", fun { less; _ } -> Boolean.not less)
     ] ;
   List.iter ~f:cmp_method
     [ ("assertLt", Field.Assert.lt)
     ; ("assertLte", Field.Assert.lte)
     ; ("assertGt", Field.Assert.gt)
     ; ("assertGte", Field.Assert.gte)
     ]) ;
  method_ "assertEquals" (fun this (y : As_field.t) : unit ->
      try Field.Assert.equal this##.value (As_field.value y)
      with _ ->
        let s =
          sprintf "assertEquals: %s != %s"
            (Js.to_string this##toString)
            (Js.to_string (As_field.to_field_obj y)##toString)
        in
        Js.raise_js_error (new%js Js.error_constr (Js.string s))) ;

  method_ "assertBoolean" (fun this : unit ->
      Impl.assert_ (Constraint.boolean this##.value)) ;
  method_ "isZero" (fun this : bool_class Js.t ->
      new%js bool_constr
        (As_bool.of_boolean (Field.equal this##.value Field.zero))) ;
  optdef_arg_method field_class "toBits"
    (fun this (length : int Js.Optdef.t) : bool_class Js.t Js.js_array Js.t ->
      let length = Js.Optdef.get length (fun () -> Field.size_in_bits) in
      let k f bits =
        let arr = new%js Js.array_empty in
        List.iter bits ~f:(fun x ->
            arr##push (new%js bool_constr (As_bool.of_boolean (f x))) |> ignore) ;
        arr
      in
      handle_constants
        (fun v -> k Fn.id (Field.choose_preimage_var ~length v))
        (fun x ->
          let bits = Field.Constant.unpack x in
          let bits, high_bits = List.split_n bits length in
          if List.exists high_bits ~f:Fn.id then
            raise_error
              (sprintf "Value %s did not fit in %d bits"
                 (Field.Constant.to_string x)
                 length) ;
          k Boolean.var_of_value bits)
        this##.value) ;
  method_ "equals" (fun this (y : As_field.t) : bool_class Js.t ->
      new%js bool_constr
        (As_bool.of_boolean (Field.equal this##.value (As_field.value y)))) ;
  let static_op1 name (f : Field.t -> Field.t) =
    Js.Unsafe.set field_class (Js.string name)
      (Js.wrap_callback (fun (x : As_field.t) : field_class Js.t ->
           mk (f (As_field.value x))))
  in
  let static_op2 name (f : Field.t -> Field.t -> Field.t) =
    Js.Unsafe.set field_class (Js.string name)
      (Js.wrap_callback
         (fun (x : As_field.t) (y : As_field.t) : field_class Js.t ->
           mk (f (As_field.value x) (As_field.value y))))
  in
  field_class##.one := mk Field.one ;
  field_class##.zero := mk Field.zero ;
  field_class##.random :=
    Js.wrap_callback (fun () : field_class Js.t ->
        mk (Field.constant (Field.Constant.random ()))) ;
  static_op2 "add" Field.add ;
  static_op2 "sub" sub ;
  static_op2 "mul" Field.mul ;
  static_op2 "div" div ;
  static_op1 "neg" Field.negate ;
  static_op1 "inv" Field.inv ;
  static_op1 "square" Field.square ;
  static_op1 "sqrt" sqrt ;
  field_class##.toString :=
    Js.wrap_callback (fun (x : As_field.t) : Js.js_string Js.t ->
        to_string (As_field.value x)) ;
  field_class##.sizeInFields := Js.wrap_callback (fun () : int -> 1) ;
  field_class##.toFields :=
    Js.wrap_callback
      (fun (x : As_field.t) : field_class Js.t Js.js_array Js.t ->
        (As_field.to_field_obj x)##toFields) ;
  field_class##.ofFields :=
    Js.wrap_callback
      (fun (xs : field_class Js.t Js.js_array Js.t) : field_class Js.t ->
        array_check_length xs 1 ; array_get_exn xs 0) ;
  field_class##.assertEqual :=
    Js.wrap_callback (fun (x : As_field.t) (y : As_field.t) : unit ->
        Field.Assert.equal (As_field.value x) (As_field.value y)) ;
  field_class##.assertBoolean
  := Js.wrap_callback (fun (x : As_field.t) : unit ->
         Impl.assert_ (Constraint.boolean (As_field.value x))) ;
  field_class##.isZero :=
    Js.wrap_callback (fun (x : As_field.t) : bool_class Js.t ->
        new%js bool_constr
          (As_bool.of_boolean (Field.equal (As_field.value x) Field.zero))) ;
  field_class##.ofBits :=
    Js.wrap_callback
      (fun (bs : As_bool.t Js.js_array Js.t) : field_class Js.t ->
        try
          Array.map (Js.to_array bs) ~f:(fun b ->
              match (As_bool.value b :> Impl.Field.t) with
              | Constant b ->
                  Impl.Field.Constant.(equal one b)
              | _ ->
                  failwith "non-constant")
          |> Array.to_list |> Field.Constant.project |> Field.constant |> mk
        with _ ->
          mk
            (Field.pack
               (List.init bs##.length ~f:(fun i ->
                    Js.Optdef.case (Js.array_get bs i)
                      (fun () -> assert false)
                      As_bool.value)))) ;
  (field_class##.toBits :=
     let wrapper =
       Js.Unsafe.eval_string
         {js|
          (function(toField) {
            return function(x, length) {
              return toField(x).toBits(length);
            };
          })|js}
     in
     Js.Unsafe.(
       fun_call wrapper [| inject (Js.wrap_callback As_field.to_field_obj) |])) ;
  field_class##.equal :=
    Js.wrap_callback (fun (x : As_field.t) (y : As_field.t) : bool_class Js.t ->
        new%js bool_constr
          (As_bool.of_boolean
             (Field.equal (As_field.value x) (As_field.value y)))) ;
  let static_method name f =
    Js.Unsafe.set field_class (Js.string name) (Js.wrap_callback f)
  in
  method_ "seal"
    (let seal = Pickles.Util.seal (module Impl) in
     fun (this : field_class Js.t) : field_class Js.t -> mk (seal this##.value)) ;
  method_ "rangeCheckHelper"
    (fun (this : field_class Js.t) (num_bits : int) : field_class Js.t ->
      match this##.value with
      | Constant v ->
          let n = Bigint.of_field v in
          for i = num_bits to Field.size_in_bits - 1 do
            if Bigint.test_bit n i then
              raise_error
                (sprintf
                   !"rangeCheckHelper: Expected %{sexp:Field.Constant.t} to \
                     fit in %d bits"
                   v num_bits)
          done ;
          this
      | v ->
          let _a, _b, n =
            Pickles.Scalar_challenge.to_field_checked' ~num_bits
              (module Impl)
              { inner = v }
          in
          mk n) ;
  method_ "isConstant" (fun (this : field_class Js.t) : bool Js.t ->
      match this##.value with Constant _ -> Js._true | _ -> Js._false) ;
  method_ "toConstant" (fun (this : field_class Js.t) : field_class Js.t ->
      let x =
        match this##.value with Constant x -> x | x -> As_prover.read_var x
      in
      mk (Field.constant x)) ;
  method_ "toJSON" (fun (this : field_class Js.t) : < .. > Js.t ->
      this##toString) ;
  static_method "toJSON" (fun (this : field_class Js.t) : < .. > Js.t ->
      this##toJSON) ;
  static_method "fromJSON"
    (fun (value : Js.Unsafe.any) : field_class Js.t Js.Opt.t ->
      let return x =
        Js.Opt.return (new%js field_constr (As_field.of_field x))
      in
      match Js.to_string (Js.typeof (Js.Unsafe.coerce value)) with
      | "number" ->
          let value = Js.float_of_number (Obj.magic value) in
          if Caml.Float.is_integer value then
            return (Field.of_int (Float.to_int value))
          else Js.Opt.empty
      | "boolean" ->
          let value = Js.to_bool (Obj.magic value) in
          return (if value then Field.one else Field.zero)
      | "string" -> (
          let value : Js.js_string Js.t = Obj.magic value in
          let s = Js.to_string value in
          try
            return
              (Field.constant
                 ( if
                   Char.equal s.[0] '0' && Char.equal (Char.lowercase s.[1]) 'x'
                 then Kimchi_pasta.Pasta.Fp.(of_bigint (Bigint.of_hex_string s))
                 else Field.Constant.of_string s ))
          with Failure _ -> Js.Opt.empty )
      | _ ->
          Js.Opt.empty) ;
  mk

let () =
  let handle_constants2 f f_constant (x : Boolean.var) (y : Boolean.var) =
    match ((x :> Field.t), (y :> Field.t)) with
    | Constant x, Constant y ->
        f_constant x y
    | _ ->
        f x y
  in
  let equal =
    handle_constants2 Boolean.equal (fun x y ->
        Boolean.var_of_value (Field.Constant.equal x y))
  in
  let mk x : bool_class Js.t = new%js bool_constr (As_bool.of_boolean x) in
  let method_ name (f : bool_class Js.t -> _) = method_ bool_class name f in
  let add_op1 name (f : Boolean.var -> Boolean.var) =
    method_ name (fun this : bool_class Js.t -> mk (f this##.value))
  in
  let add_op2 name (f : Boolean.var -> Boolean.var -> Boolean.var) =
    method_ name (fun this (y : As_bool.t) : bool_class Js.t ->
        mk (f this##.value (As_bool.value y)))
  in
  method_ "toField" (fun this : field_class Js.t ->
      new%js field_constr (As_field.of_field (this##.value :> Field.t))) ;
  add_op1 "not" Boolean.not ;
  add_op2 "and" Boolean.( &&& ) ;
  add_op2 "or" Boolean.( ||| ) ;
  method_ "assertEquals" (fun this (y : As_bool.t) : unit ->
      Boolean.Assert.( = ) this##.value (As_bool.value y)) ;
  add_op2 "equals" equal ;
  method_ "toBoolean" (fun this : bool Js.t ->
      match (this##.value :> Field.t) with
      | Constant x ->
          Js.bool Field.Constant.(equal one x)
      | _ -> (
          try Js.bool (As_prover.read Boolean.typ this##.value)
          with _ ->
            raise_error
              "Bool.toBoolean can only be called on non-witness values." )) ;
  method_ "sizeInFields" (fun _this : int -> 1) ;
  method_ "toString" (fun this ->
      let x =
        match (this##.value :> Field.t) with
        | Constant x ->
            x
        | x ->
            As_prover.read_var x
      in
      if Field.Constant.(equal one) x then "true" else "false") ;
  method_ "toFields" (fun this : field_class Js.t Js.js_array Js.t ->
      let arr = new%js Js.array_empty in
      arr##push this##toField |> ignore ;
      arr) ;
  let static_method name f =
    Js.Unsafe.set bool_class (Js.string name) (Js.wrap_callback f)
  in
  let static_op1 name (f : Boolean.var -> Boolean.var) =
    static_method name (fun (x : As_bool.t) : bool_class Js.t ->
        mk (f (As_bool.value x)))
  in
  let static_op2 name (f : Boolean.var -> Boolean.var -> Boolean.var) =
    static_method name (fun (x : As_bool.t) (y : As_bool.t) : bool_class Js.t ->
        mk (f (As_bool.value x) (As_bool.value y)))
  in
  static_method "toField" (fun (x : As_bool.t) ->
      new%js field_constr (As_field.of_field (As_bool.value x :> Field.t))) ;
  Js.Unsafe.set bool_class (Js.string "Unsafe")
    (object%js
       method ofField (x : As_field.t) : bool_class Js.t =
         new%js bool_constr
           (As_bool.of_boolean (Boolean.Unsafe.of_cvar (As_field.value x)))
    end) ;
  static_op1 "not" Boolean.not ;
  static_op2 "and" Boolean.( &&& ) ;
  static_op2 "or" Boolean.( ||| ) ;
  static_method "assertEqual" (fun (x : As_bool.t) (y : As_bool.t) : unit ->
      Boolean.Assert.( = ) (As_bool.value x) (As_bool.value y)) ;
  static_op2 "equal" equal ;
  static_method "count"
    (fun (bs : As_bool.t Js.js_array Js.t) : field_class Js.t ->
      new%js field_constr
        (As_field.of_field
           (Field.sum
              (List.init bs##.length ~f:(fun i ->
                   ( Js.Optdef.case (Js.array_get bs i)
                       (fun () -> assert false)
                       As_bool.value
                     :> Field.t )))))) ;
  static_method "sizeInFields" (fun () : int -> 1) ;
  static_method "toFields"
    (fun (x : As_bool.t) : field_class Js.t Js.js_array Js.t ->
      singleton_array
        (new%js field_constr (As_field.of_field (As_bool.value x :> Field.t)))) ;
  static_method "ofFields"
    (fun (xs : field_class Js.t Js.js_array Js.t) : bool_class Js.t ->
      if xs##.length = 1 then
        Js.Optdef.case (Js.array_get xs 0)
          (fun () -> assert false)
          (fun x -> mk (Boolean.Unsafe.of_cvar x##.value))
      else raise_error "Expected array of length 1") ;
  static_method "check" (fun (x : bool_class Js.t) : unit ->
      Impl.assert_ (Constraint.boolean (x##.value :> Field.t))) ;
  method_ "toJSON" (fun (this : bool_class Js.t) : < .. > Js.t ->
      Js.Unsafe.coerce this##toBoolean) ;
  static_method "toJSON" (fun (this : bool_class Js.t) : < .. > Js.t ->
      this##toJSON) ;
  static_method "fromJSON"
    (fun (value : Js.Unsafe.any) : bool_class Js.t Js.Opt.t ->
      match Js.to_string (Js.typeof (Js.Unsafe.coerce value)) with
      | "boolean" ->
          Js.Opt.return
            (new%js bool_constr (As_bool.of_js_bool (Js.Unsafe.coerce value)))
      | _ ->
          Js.Opt.empty)

type coords = < x : As_field.t Js.prop ; y : As_field.t Js.prop > Js.t

let group_class : < .. > Js.t =
  let f =
    Js.Unsafe.eval_string
      {js|
      (function(toFieldObj) {
        return function() {
          var err = 'Group constructor expects either 2 arguments (x, y) or a single argument object { x, y }';
          if (arguments.length == 1) {
            var t = arguments[0];
            if (t.x === undefined || t.y === undefined) {
              throw (Error(err));
            } else {
              this.x = toFieldObj(t.x);
              this.y = toFieldObj(t.y);
            }
          } else if (arguments.length == 2) {
            this.x = toFieldObj(arguments[0]);
            this.y = toFieldObj(arguments[1]);
          } else {
            throw (Error(err));
          }
          return this;
        }
      })
      |js}
  in
  Js.Unsafe.fun_call f
    [| Js.Unsafe.inject (Js.wrap_callback As_field.to_field_obj) |]

class type scalar_class =
  object
    method value : Boolean.var array Js.prop

    method constantValue : Other_impl.Field.Constant.t Js.Optdef.t Js.prop

    method toJSON : < .. > Js.t Js.meth
  end

class type endo_scalar_class =
  object
    method value : Boolean.var list Js.prop
  end

module As_group = struct
  (* { x: as_field, y : as_field } | group_class *)
  type t

  class type group_class =
    object
      method x : field_class Js.t Js.prop

      method y : field_class Js.t Js.prop

      method add : group_class Js.t -> group_class Js.t Js.meth

      method add_ : t -> group_class Js.t Js.meth

      method sub_ : t -> group_class Js.t Js.meth

      method neg : group_class Js.t Js.meth

      method scale : scalar_class Js.t -> group_class Js.t Js.meth

      method endoScale : endo_scalar_class Js.t -> group_class Js.t Js.meth

      method assertEquals : t -> unit Js.meth

      method equals : t -> bool_class Js.t Js.meth

      method toJSON : < .. > Js.t Js.meth

      method toFields : field_class Js.t Js.js_array Js.t Js.meth
    end

  let group_constr : (As_field.t -> As_field.t -> group_class Js.t) Js.constr =
    Obj.magic group_class

  let to_coords (t : t) : coords = Obj.magic t

  let value (t : t) =
    let t = to_coords t in
    (As_field.value t##.x, As_field.value t##.y)

  let of_group_obj (t : group_class Js.t) : t = Obj.magic t

  let to_group_obj (t : t) : group_class Js.t =
    if Js.instanceof (Obj.magic t) group_constr then Obj.magic t
    else
      let t = to_coords t in
      new%js group_constr t##.x t##.y
end

class type group_class = As_group.group_class

let group_constr = As_group.group_constr

let scalar_shift =
  Pickles_types.Shifted_value.Type1.Shift.create (module Other_backend.Field)

let to_constant_scalar (bs : Boolean.var array) :
    Other_backend.Field.t Js.Optdef.t =
  with_return (fun { return } ->
      let bs =
        Array.map bs ~f:(fun b ->
            match (b :> Field.t) with
            | Constant b ->
                Impl.Field.Constant.(equal one b)
            | _ ->
                return Js.Optdef.empty)
      in
      Js.Optdef.return
        (Pickles_types.Shifted_value.Type1.to_field
           (module Other_backend.Field)
           ~shift:scalar_shift
           (Shifted_value (Other_backend.Field.of_bits (Array.to_list bs)))))

let scalar_class : < .. > Js.t =
  let f =
    Js.Unsafe.eval_string
      {js|
      (function(toConstantFieldElt) {
        return function(bits, constantValue) {
          this.value = bits;
          if (constantValue !== undefined) {
            this.constantValue = constantValue;
            return this;
          }
          let c = toConstantFieldElt(bits);
          if (c !== undefined) {
            this.constantValue = c;
          }
          return this;
        };
      })
    |js}
  in
  Js.Unsafe.(fun_call f [| inject (Js.wrap_callback to_constant_scalar) |])

let scalar_constr : (Boolean.var array -> scalar_class Js.t) Js.constr =
  Obj.magic scalar_class

let scalar_constr_const :
    (Boolean.var array -> Other_backend.Field.t -> scalar_class Js.t) Js.constr
    =
  Obj.magic scalar_class

let () =
  let num_bits = Field.size_in_bits in
  let method_ name (f : scalar_class Js.t -> _) = method_ scalar_class name f in
  let static_method name f =
    Js.Unsafe.set scalar_class (Js.string name) (Js.wrap_callback f)
  in
  let ( ! ) name x =
    Js.Optdef.get x (fun () ->
        raise_error
          (sprintf "Scalar.%s can only be called on non-witness values." name))
  in
  let bits x =
    let (Shifted_value x) =
      Pickles_types.Shifted_value.Type1.of_field ~shift:scalar_shift
        (module Other_backend.Field)
        x
    in
    Array.of_list_map (Other_backend.Field.to_bits x) ~f:Boolean.var_of_value
  in
  let constant_op1 name (f : Other_backend.Field.t -> Other_backend.Field.t) =
    method_ name (fun x : scalar_class Js.t ->
        let z = f (!name x##.constantValue) in
        new%js scalar_constr_const (bits z) z)
  in
  let constant_op2 name
      (f :
        Other_backend.Field.t -> Other_backend.Field.t -> Other_backend.Field.t)
      =
    let ( ! ) = !name in
    method_ name (fun x (y : scalar_class Js.t) : scalar_class Js.t ->
        let z = f !(x##.constantValue) !(y##.constantValue) in
        new%js scalar_constr_const (bits z) z)
  in

  (* It is not necessary to boolean constrain the bits of a scalar for the following
     reasons:

     The only type-safe functions which can be called with a scalar value are

     - if
     - assertEqual
     - equal
     - Group.scale

     The only one of these whose behavior depends on the bit values of the input scalars
     is Group.scale, and that function boolean constrains the scalar input itself.
  *)
  constant_op1 "neg" Other_backend.Field.negate ;
  constant_op2 "add" Other_backend.Field.add ;
  constant_op2 "mul" Other_backend.Field.mul ;
  constant_op2 "sub" Other_backend.Field.sub ;
  constant_op2 "div" Other_backend.Field.div ;
  method_ "toFields" (fun x : field_class Js.t Js.js_array Js.t ->
      Array.map x##.value ~f:(fun b ->
          new%js field_constr (As_field.of_field (b :> Field.t)))
      |> Js.array) ;
  static_method "toFields"
    (fun (x : scalar_class Js.t) : field_class Js.t Js.js_array Js.t ->
      (Js.Unsafe.coerce x)##toFields) ;
  static_method "sizeInFields" (fun () : int -> num_bits) ;
  static_method "ofFields"
    (fun (xs : field_class Js.t Js.js_array Js.t) : scalar_class Js.t ->
      new%js scalar_constr
        (Array.map (Js.to_array xs) ~f:(fun x ->
             Boolean.Unsafe.of_cvar x##.value))) ;
  static_method "random" (fun () : scalar_class Js.t ->
      let x = Other_backend.Field.random () in
      new%js scalar_constr_const (bits x) x) ;
  static_method "ofBits"
    (fun (bits : bool_class Js.t Js.js_array Js.t) : scalar_class Js.t ->
      new%js scalar_constr
        (Array.map (Js.to_array bits) ~f:(fun b ->
             As_bool.(value (of_bool_obj b))))) ;
  method_ "toJSON" (fun (s : scalar_class Js.t) : < .. > Js.t ->
      let s =
        Js.Optdef.case s##.constantValue
          (fun () ->
            Js.Optdef.get
              (to_constant_scalar s##.value)
              (fun () -> raise_error "Cannot convert in-circuit value to JSON"))
          Fn.id
      in
      Js.string (Other_impl.Field.Constant.to_string s)) ;
  static_method "toJSON" (fun (s : scalar_class Js.t) : < .. > Js.t ->
      s##toJSON) ;
  static_method "fromJSON"
    (fun (value : Js.Unsafe.any) : scalar_class Js.t Js.Opt.t ->
      let return x = Js.Opt.return (new%js scalar_constr_const (bits x) x) in
      match Js.to_string (Js.typeof (Js.Unsafe.coerce value)) with
      | "number" ->
          let value = Js.float_of_number (Obj.magic value) in
          if Caml.Float.is_integer value then
            return (Other_backend.Field.of_int (Float.to_int value))
          else Js.Opt.empty
      | "boolean" ->
          let value = Js.to_bool (Obj.magic value) in
          return Other_backend.(if value then Field.one else Field.zero)
      | "string" -> (
          let value : Js.js_string Js.t = Obj.magic value in
          let s = Js.to_string value in
          try
            return
              ( if Char.equal s.[0] '0' && Char.equal (Char.lowercase s.[1]) 'x'
              then Kimchi_pasta.Pasta.Fq.(of_bigint (Bigint.of_hex_string s))
              else Other_impl.Field.Constant.of_string s )
          with Failure _ -> Js.Opt.empty )
      | _ ->
          Js.Opt.empty)

let () =
  let mk (x, y) : group_class Js.t =
    new%js group_constr (As_field.of_field x) (As_field.of_field y)
  in
  let method_ name (f : group_class Js.t -> _) = method_ group_class name f in
  let static name x = Js.Unsafe.set group_class (Js.string name) x in
  let static_method name f = static name (Js.wrap_callback f) in
  let constant (x, y) = mk Field.(constant x, constant y) in
  method_ "add"
    (fun (p1 : group_class Js.t) (p2 : As_group.t) : group_class Js.t ->
      let p1, p2 =
        (As_group.value (As_group.of_group_obj p1), As_group.value p2)
      in
      match (p1, p2) with
      | (Constant x1, Constant y1), (Constant x2, Constant y2) ->
          constant
            (Pickles.Step_main_inputs.Inner_curve.Constant.( + ) (x1, y1)
               (x2, y2))
      | _ ->
          Pickles.Step_main_inputs.Ops.add_fast p1 p2 |> mk) ;
  method_ "neg" (fun (p1 : group_class Js.t) : group_class Js.t ->
      Pickles.Step_main_inputs.Inner_curve.negate
        (As_group.value (As_group.of_group_obj p1))
      |> mk) ;
  method_ "sub"
    (fun (p1 : group_class Js.t) (p2 : As_group.t) : group_class Js.t ->
      p1##add (As_group.to_group_obj p2)##neg) ;
  method_ "scale"
    (fun (p1 : group_class Js.t) (s : scalar_class Js.t) : group_class Js.t ->
      match
        ( As_group.(value (of_group_obj p1))
        , Js.Optdef.to_option s##.constantValue )
      with
      | (Constant x, Constant y), Some s ->
          Pickles.Step_main_inputs.Inner_curve.Constant.scale (x, y) s
          |> constant
      | _ ->
          let bits = Array.copy s##.value in
          (* Have to convert LSB -> MSB *)
          Array.rev_inplace bits ;
          Pickles.Step_main_inputs.Ops.scale_fast_msb_bits
            (As_group.value (As_group.of_group_obj p1))
            (Shifted_value bits)
          |> mk) ;
  (* TODO
     method_ "endoScale"
       (fun (p1 : group_class Js.t) (s : endo_scalar_class Js.t) : group_class Js.t
       ->
         Sc.endo
           (As_group.value (As_group.of_group_obj p1))
           (Scalar_challenge s##.value)
         |> mk) ; *)
  method_ "assertEquals"
    (fun (p1 : group_class Js.t) (p2 : As_group.t) : unit ->
      let x1, y1 = As_group.value (As_group.of_group_obj p1) in
      let x2, y2 = As_group.value p2 in
      Field.Assert.equal x1 x2 ; Field.Assert.equal y1 y2) ;
  method_ "equals"
    (fun (p1 : group_class Js.t) (p2 : As_group.t) : bool_class Js.t ->
      let x1, y1 = As_group.value (As_group.of_group_obj p1) in
      let x2, y2 = As_group.value p2 in
      new%js bool_constr
        (As_bool.of_boolean
           (Boolean.all [ Field.equal x1 x2; Field.equal y1 y2 ]))) ;
  static "generator"
    (mk Pickles.Step_main_inputs.Inner_curve.one : group_class Js.t) ;
  static_method "add"
    (fun (p1 : As_group.t) (p2 : As_group.t) : group_class Js.t ->
      (As_group.to_group_obj p1)##add_ p2) ;
  static_method "sub"
    (fun (p1 : As_group.t) (p2 : As_group.t) : group_class Js.t ->
      (As_group.to_group_obj p1)##sub_ p2) ;
  static_method "sub"
    (fun (p1 : As_group.t) (p2 : As_group.t) : group_class Js.t ->
      (As_group.to_group_obj p1)##sub_ p2) ;
  static_method "neg" (fun (p1 : As_group.t) : group_class Js.t ->
      (As_group.to_group_obj p1)##neg) ;
  static_method "scale"
    (fun (p1 : As_group.t) (s : scalar_class Js.t) : group_class Js.t ->
      (As_group.to_group_obj p1)##scale s) ;
  static_method "assertEqual" (fun (p1 : As_group.t) (p2 : As_group.t) : unit ->
      (As_group.to_group_obj p1)##assertEquals p2) ;
  static_method "equal"
    (fun (p1 : As_group.t) (p2 : As_group.t) : bool_class Js.t ->
      (As_group.to_group_obj p1)##equals p2) ;
  method_ "toFields"
    (fun (p1 : group_class Js.t) : field_class Js.t Js.js_array Js.t ->
      let arr = singleton_array p1##.x in
      arr##push p1##.y |> ignore ;
      arr) ;
  static_method "toFields" (fun (p1 : group_class Js.t) -> p1##toFields) ;
  static_method "ofFields" (fun (xs : field_class Js.t Js.js_array Js.t) ->
      array_check_length xs 2 ;
      new%js group_constr
        (As_field.of_field_obj (array_get_exn xs 0))
        (As_field.of_field_obj (array_get_exn xs 1))) ;
  static_method "sizeInFields" (fun () : int -> 2) ;
  static_method "check" (fun (p : group_class Js.t) : unit ->
      Pickles.Step_main_inputs.Inner_curve.assert_on_curve
        Field.((p##.x##.value :> t), (p##.y##.value :> t))) ;
  method_ "toJSON" (fun (p : group_class Js.t) : < .. > Js.t ->
      object%js
        val x = (Obj.magic field_class)##toJSON p##.x

        val y = (Obj.magic field_class)##toJSON p##.y
      end) ;
  static_method "toJSON" (fun (p : group_class Js.t) : < .. > Js.t -> p##toJSON) ;
  static_method "fromJSON"
    (fun (value : Js.Unsafe.any) : group_class Js.t Js.Opt.t ->
      let get field_name =
        Js.Optdef.case
          (Js.Unsafe.get value (Js.string field_name))
          (fun () -> Js.Opt.empty)
          (fun x -> field_class##fromJSON x)
      in
      Js.Opt.bind (get "x") (fun x ->
          Js.Opt.map (get "y") (fun y ->
              new%js group_constr
                (As_field.of_field_obj x) (As_field.of_field_obj y))))

class type ['a] as_field_elements =
  object
    method toFields : 'a -> field_class Js.t Js.js_array Js.t Js.meth

    method ofFields : field_class Js.t Js.js_array Js.t -> 'a Js.meth

    method sizeInFields : int Js.meth
  end

let array_iter t1 ~f =
  for i = 0 to t1##.length - 1 do
    f (array_get_exn t1 i)
  done

let array_iter2 t1 t2 ~f =
  for i = 0 to t1##.length - 1 do
    f (array_get_exn t1 i) (array_get_exn t2 i)
  done

let array_map t1 ~f =
  let res = new%js Js.array_empty in
  array_iter t1 ~f:(fun x1 -> res##push (f x1) |> ignore) ;
  res

let array_map2 t1 t2 ~f =
  let res = new%js Js.array_empty in
  array_iter2 t1 t2 ~f:(fun x1 x2 -> res##push (f x1 x2) |> ignore) ;
  res

let poseidon =
  object%js
    method hash (xs : field_class Js.t Js.js_array Js.t) : field_class Js.t =
      match
        array_map xs ~f:(fun x ->
            match x##.value with Constant x -> x | x -> As_prover.read_var x)
      with
      | exception _ ->
          let module Sponge = Pickles.Step_main_inputs.Sponge in
          let sponge_params = Pickles.Step_main_inputs.sponge_params in
          let s = Sponge.create sponge_params in
          for i = 0 to xs##.length - 1 do
            Sponge.absorb s (`Field (array_get_exn xs i)##.value)
          done ;
          new%js field_constr (As_field.of_field (Sponge.squeeze_field s))
      | xs ->
          let module Field = Pickles.Tick_field_sponge.Field in
          let params = Pickles.Tick_field_sponge.params in
          let s = Field.create params in
          array_iter xs ~f:(Field.absorb s) ;
          new%js field_constr
            (As_field.of_field (Impl.Field.constant (Field.squeeze s)))
  end

class type verification_key_class =
  object
    method value : Verification_key.t Js.prop

    method verify :
      Js.Unsafe.any Js.js_array Js.t -> proof_class Js.t -> bool Js.t Js.meth
  end

and proof_class =
  object
    method value : Backend.Proof.t Js.prop
  end

class type keypair_class =
  object
    method value : Keypair.t Js.prop
  end

let keypair_class : < .. > Js.t =
  Js.Unsafe.eval_string {js|(function(v) { this.value = v; return this })|js}

let keypair_constr : (Keypair.t -> keypair_class Js.t) Js.constr =
  Obj.magic keypair_class

let verification_key_class : < .. > Js.t =
  Js.Unsafe.eval_string {js|(function(v) { this.value = v; return this })|js}

let verification_key_constr :
    (Verification_key.t -> verification_key_class Js.t) Js.constr =
  Obj.magic verification_key_class

let proof_class : < .. > Js.t =
  Js.Unsafe.eval_string {js|(function(v) { this.value = v; return this })|js}

let proof_constr : (Backend.Proof.t -> proof_class Js.t) Js.constr =
  Obj.magic proof_class

module Circuit = struct
  let check_lengths s t1 t2 =
    if t1##.length <> t2##.length then
      raise_error
        (sprintf "%s: Got mismatched lengths, %d != %d" s t1##.length
           t2##.length)
    else ()

  let wrap name ~pre_args ~post_args ~explicit ~implicit =
    let total_implicit = pre_args + post_args in
    let total_explicit = 1 + total_implicit in
    let wrapped =
      let err =
        if pre_args > 0 then
          sprintf
            "%s: Must be called with %d arguments, or, if passing constructor \
             explicitly, with %d arguments, followed by the constructor, \
             followed by %d arguments"
            name total_implicit pre_args post_args
        else
          sprintf
            "%s: Must be called with %d arguments, or, if passing constructor \
             explicitly, with the constructor as the first argument, followed \
             by %d arguments"
            name total_implicit post_args
      in
      ksprintf Js.Unsafe.eval_string
        {js|
        (function(explicit, implicit) {
          return function() {
            var err = '%s';
            if (arguments.length === %d) {
              return explicit.apply(this, arguments);
            } else if (arguments.length === %d) {
              return implicit.apply(this, arguments);
            } else {
              throw (Error(err));
            }
          }
        } )
      |js}
        err total_explicit total_implicit
    in
    Js.Unsafe.(
      fun_call wrapped
        [| inject (Js.wrap_callback explicit)
         ; inject (Js.wrap_callback implicit)
        |])

  let if_array b t1 t2 =
    check_lengths "if" t1 t2 ;
    array_map2 t1 t2 ~f:(fun x1 x2 ->
        new%js field_constr
          (As_field.of_field (Field.if_ b ~then_:x1##.value ~else_:x2##.value)))

  let js_equal (type b) (x : b) (y : b) : bool =
    let f = Js.Unsafe.eval_string "(function(x, y) { return x === y; })" in
    Js.to_bool Js.Unsafe.(fun_call f [| inject x; inject y |])

  let keys (type a) (a : a) : Js.js_string Js.t Js.js_array Js.t =
    Js.Unsafe.global ##. Object##keys a

  let check_type name t =
    let t = Js.to_string t in
    let ok =
      match t with
      | "object" ->
          true
      | "function" ->
          false
      | "number" ->
          false
      | "boolean" ->
          false
      | "string" ->
          false
      | _ ->
          false
    in
    if ok then ()
    else
      raise_error
        (sprintf "Type \"%s\" cannot be used with function \"%s\"" t name)

  let rec to_field_elts_magic :
      type a. a Js.t -> field_class Js.t Js.js_array Js.t =
    fun (type a) (t1 : a Js.t) : field_class Js.t Js.js_array Js.t ->
     let t1_is_array = Js.Unsafe.global ##. Array##isArray t1 in
     check_type "toFields" (Js.typeof t1) ;
     match t1_is_array with
     | true ->
         let arr = array_map (Obj.magic t1) ~f:to_field_elts_magic in
         (Obj.magic arr)##flat
     | false -> (
         let ctor1 : _ Js.Optdef.t = (Obj.magic t1)##.constructor in
         let has_methods ctor =
           let has s = Js.to_bool (ctor##hasOwnProperty (Js.string s)) in
           has "toFields" && has "ofFields"
         in
         match Js.Optdef.(to_option ctor1) with
         | Some ctor1 when has_methods ctor1 ->
             ctor1##toFields t1
         | Some _ ->
             let arr =
               array_map
                 (keys t1)##sort_asStrings
                 ~f:(fun k -> to_field_elts_magic (Js.Unsafe.get t1 k))
             in
             (Obj.magic arr)##flat
         | None ->
             raise_error "toFields: Argument did not have a constructor." )

  let assert_equal =
    let f t1 t2 =
      (* TODO: Have better error handling here that throws at proving time
         for the specific position where they differ. *)
      check_lengths "assertEqual" t1 t2 ;
      for i = 0 to t1##.length - 1 do
        Field.Assert.equal
          (array_get_exn t1 i)##.value
          (array_get_exn t2 i)##.value
      done
    in
    let implicit
        (t1 :
          < toFields : field_class Js.t Js.js_array Js.t Js.meth > Js.t as 'a)
        (t2 : 'a) : unit =
      f (to_field_elts_magic t1) (to_field_elts_magic t2)
    in
    let explicit
        (ctor :
          < toFields : 'a -> field_class Js.t Js.js_array Js.t Js.meth > Js.t)
        (t1 : 'a) (t2 : 'a) : unit =
      f (ctor##toFields t1) (ctor##toFields t2)
    in
    wrap "assertEqual" ~pre_args:0 ~post_args:2 ~explicit ~implicit

  let equal =
    let f t1 t2 =
      check_lengths "equal" t1 t2 ;
      (* TODO: Have better error handling here that throws at proving time
         for the specific position where they differ. *)
      new%js bool_constr
        ( Boolean.Array.all
            (Array.init t1##.length ~f:(fun i ->
                 Field.equal
                   (array_get_exn t1 i)##.value
                   (array_get_exn t2 i)##.value))
        |> As_bool.of_boolean )
    in
    let _implicit
        (t1 :
          < toFields : field_class Js.t Js.js_array Js.t Js.meth > Js.t as 'a)
        (t2 : 'a) : bool_class Js.t =
      f t1##toFields t2##toFields
    in
    let implicit t1 t2 = f (to_field_elts_magic t1) (to_field_elts_magic t2) in
    let explicit
        (ctor :
          < toFields : 'a -> field_class Js.t Js.js_array Js.t Js.meth > Js.t)
        (t1 : 'a) (t2 : 'a) : bool_class Js.t =
      f (ctor##toFields t1) (ctor##toFields t2)
    in
    wrap "equal" ~pre_args:0 ~post_args:2 ~explicit ~implicit

  let if_explicit (type a) (b : As_bool.t) (ctor : a as_field_elements Js.t)
      (x1 : a) (x2 : a) =
    let b = As_bool.value b in
    match (b :> Field.t) with
    | Constant b ->
        if Field.Constant.(equal one b) then x1 else x2
    | _ ->
        let t1 = ctor##toFields x1 in
        let t2 = ctor##toFields x2 in
        let arr = if_array b t1 t2 in
        ctor##ofFields arr

  let rec if_magic : type a. As_bool.t -> a Js.t -> a Js.t -> a Js.t =
    fun (type a) (b : As_bool.t) (t1 : a Js.t) (t2 : a Js.t) : a Js.t ->
     check_type "if" (Js.typeof t1) ;
     check_type "if" (Js.typeof t2) ;
     let t1_is_array = Js.Unsafe.global ##. Array##isArray t1 in
     let t2_is_array = Js.Unsafe.global ##. Array##isArray t2 in
     match (t1_is_array, t2_is_array) with
     | false, true | true, false ->
         raise_error "if: Mismatched argument types"
     | true, true ->
         array_map2 (Obj.magic t1) (Obj.magic t2) ~f:(fun x1 x2 ->
             if_magic b x1 x2)
         |> Obj.magic
     | false, false -> (
         let ctor1 : _ Js.Optdef.t = (Obj.magic t1)##.constructor in
         let ctor2 : _ Js.Optdef.t = (Obj.magic t2)##.constructor in
         let has_methods ctor =
           let has s = Js.to_bool (ctor##hasOwnProperty (Js.string s)) in
           has "toFields" && has "ofFields"
         in
         if not (js_equal ctor1 ctor2) then
           raise_error "if: Mismatched argument types" ;
         match Js.Optdef.(to_option ctor1, to_option ctor2) with
         | Some ctor1, Some _ when has_methods ctor1 ->
             if_explicit b ctor1 t1 t2
         | Some ctor1, Some _ ->
             (* Try to match them as generic objects *)
             let ks1 = (keys t1)##sort_asStrings in
             let ks2 = (keys t2)##sort_asStrings in
             check_lengths
               (sprintf "if (%s vs %s)"
                  (Js.to_string (ks1##join (Js.string ", ")))
                  (Js.to_string (ks2##join (Js.string ", "))))
               ks1 ks2 ;
             array_iter2 ks1 ks2 ~f:(fun k1 k2 ->
                 if not (js_equal k1 k2) then
                   raise_error "if: Arguments had mismatched types") ;
             let result = new%js ctor1 in
             array_iter ks1 ~f:(fun k ->
                 Js.Unsafe.set result k
                   (if_magic b (Js.Unsafe.get t1 k) (Js.Unsafe.get t2 k))) ;
             Obj.magic result
         | Some _, None | None, Some _ ->
             assert false
         | None, None ->
             raise_error "if: Arguments did not have a constructor." )

  let if_ =
    wrap "if" ~pre_args:1 ~post_args:2 ~explicit:if_explicit ~implicit:if_magic

  let typ_ (type a) (typ : a as_field_elements Js.t) : (a, a) Typ.t =
    let to_array conv a =
      Js.to_array (typ##toFields a) |> Array.map ~f:(fun x -> conv x##.value)
    in
    let of_array conv xs =
      typ##ofFields
        (Js.array
           (Array.map xs ~f:(fun x ->
                new%js field_constr (As_field.of_field (conv x)))))
    in
    Typ.transport
      (Typ.array ~length:typ##sizeInFields Field.typ)
      ~there:(to_array (fun x -> Option.value_exn (Field.to_constant x)))
      ~back:(of_array Field.constant)
    |> Typ.transport_var ~there:(to_array Fn.id) ~back:(of_array Fn.id)

  let witness (type a) (typ : a as_field_elements Js.t)
      (f : (unit -> a) Js.callback) : a =
    let a =
      Impl.exists (typ_ typ) ~compute:(fun () : a -> Js.Unsafe.fun_call f [||])
    in
    if Js.Optdef.test (Js.Unsafe.coerce typ)##.check then
      (Js.Unsafe.coerce typ)##check a ;
    a

  module Circuit_main = struct
    type ('w, 'p) t =
      < snarkyMain : ('w -> 'p -> unit) Js.callback Js.prop
      ; snarkyWitnessTyp : 'w as_field_elements Js.t Js.prop
      ; snarkyPublicTyp : 'p as_field_elements Js.t Js.prop >
      Js.t
  end

  module Promise : sig
    type _ t

    val return : 'a -> 'a t

    val map : 'a t -> f:('a -> 'b) -> 'b t
  end = struct
    (* type 'a t = < then_: 'b. ('a -> 'b) Js.callback -> 'b t Js.meth > Js.t *)
    type 'a t = < > Js.t

    let constr = Obj.magic Js.Unsafe.global ##. Promise

    let return (type a) (x : a) : a t =
      new%js constr
        (Js.wrap_callback (fun resolve ->
             Js.Unsafe.(fun_call resolve [| inject x |])))

    let map (type a b) (t : a t) ~(f : a -> b) : b t =
      (Js.Unsafe.coerce t)##then_ (Js.wrap_callback (fun (x : a) -> f x))
  end

  let main_and_input (type w p) (c : (w, p) Circuit_main.t) =
    let main ?(w : w option) (public : p) () =
      let w : w =
        witness c##.snarkyWitnessTyp
          (Js.wrap_callback (fun () -> Option.value_exn w))
      in
      Js.Unsafe.(fun_call c##.snarkyMain [| inject w; inject public |])
    in
    (main, Impl.Data_spec.[ typ_ c##.snarkyPublicTyp ])

  let generate_keypair (type w p) (c : (w, p) Circuit_main.t) :
      keypair_class Js.t =
    let main, spec = main_and_input c in
    new%js keypair_constr
      (Impl.generate_keypair ~exposing:spec (fun x -> main x))

  let prove (type w p) (c : (w, p) Circuit_main.t) (priv : w) (pub : p) kp :
      proof_class Js.t =
    let main, spec = main_and_input c in
    let pk = Keypair.pk kp in
    let p =
      Impl.generate_witness_conv
        ~f:(fun { Impl.Proof_inputs.auxiliary_inputs; public_inputs } ->
          Backend.Proof.create pk ~auxiliary:auxiliary_inputs
            ~primary:public_inputs)
        spec (main ~w:priv) () pub
    in
    new%js proof_constr p

  let circuit = Js.Unsafe.eval_string {js|(function() { return this })|js}

  let () =
    let array (type a) (typ : a as_field_elements Js.t) (length : int) :
        a Js.js_array Js.t as_field_elements Js.t =
      let elt_len = typ##sizeInFields in
      let len = length * elt_len in
      object%js
        method sizeInFields = len

        method toFields (xs : a Js.js_array Js.t) =
          let res = new%js Js.array_empty in
          for i = 0 to xs##.length - 1 do
            let x = typ##toFields (array_get_exn xs i) in
            for j = 0 to x##.length - 1 do
              res##push (array_get_exn x j) |> ignore
            done
          done ;
          res

        method ofFields (xs : field_class Js.t Js.js_array Js.t) =
          let res = new%js Js.array_empty in
          for i = 0 to length - 1 do
            let a = new%js Js.array_empty in
            let offset = i * elt_len in
            for j = 0 to elt_len - 1 do
              a##push (array_get_exn xs (offset + j)) |> ignore
            done ;
            res##push (typ##ofFields a) |> ignore
          done ;
          res
      end
    in
    let module Run_and_check_deferred = Impl.Run_and_check_deferred (Promise) in
    let call (type b) (f : (unit -> b) Js.callback) =
      Js.Unsafe.(fun_call f [||])
    in
    circuit##.runAndCheck :=
      Js.wrap_callback
        (fun (type a)
             (f : (unit -> (unit -> a) Js.callback Promise.t) Js.callback) :
             a Promise.t ->
          Run_and_check_deferred.run_and_check
            (fun () ->
              let g : (unit -> a) Js.callback Promise.t = call f in
              Promise.map g ~f:(fun (p : (unit -> a) Js.callback) () -> call p))
            ()
          |> Promise.map ~f:(fun r ->
                 let (), res = Or_error.ok_exn r in
                 res)
          (*
          Impl.run_and_check (fun () ->
              fun () -> Js.Unsafe.fun_call g [||] ) 
            ()
          |> Or_error.ok_exn
        in
        res *)) ;
    circuit##.asProver :=
      Js.wrap_callback (fun (f : (unit -> unit) Js.callback) : unit ->
          Impl.as_prover (fun () -> Js.Unsafe.fun_call f [||])) ;
    circuit##.witness := Js.wrap_callback witness ;
    circuit##.array := Js.wrap_callback array ;
    circuit##.generateKeypair :=
      Js.wrap_meth_callback
        (fun (this : _ Circuit_main.t) : keypair_class Js.t ->
          generate_keypair this) ;
    circuit##.prove :=
      Js.wrap_meth_callback
        (fun (this : _ Circuit_main.t) w p (kp : keypair_class Js.t) ->
          prove this w p kp##.value) ;
    (circuit##.verify :=
       fun (pub : Js.Unsafe.any Js.js_array Js.t)
           (vk : verification_key_class Js.t) (pi : proof_class Js.t) :
           bool Js.t ->
         vk##verify pub pi) ;
    circuit##.assertEqual := assert_equal ;
    circuit##.equal := equal ;
    circuit##.toFields := Js.wrap_callback to_field_elts_magic ;
    circuit##.inProver :=
      Js.wrap_callback (fun () : bool Js.t -> Js.bool (Impl.in_prover ())) ;
    circuit##.inCheckedComputation
    := Js.wrap_callback (fun () : bool Js.t ->
           Js.bool (Impl.in_checked_computation ())) ;
    Js.Unsafe.set circuit (Js.string "if") if_
end

let () =
  let method_ name (f : keypair_class Js.t -> _) =
    method_ keypair_class name f
  in
  method_ "verificationKey"
    (fun (this : keypair_class Js.t) : verification_key_class Js.t ->
      new%js verification_key_constr (Keypair.vk this##.value))

let () =
  let method_ name (f : verification_key_class Js.t -> _) =
    method_ verification_key_class name f
  in
  (* TODO
     let module M = struct
       type t =
         ( Backend.Field.t
         , Kimchi.Protocol.SRS.Fp. Marlin_plonk_bindings_pasta_fp_urs.t
         , Pasta.Vesta.Affine.Stable.Latest.t
             Marlin_plonk_bindings.Types.Poly_comm.t
         )
         Marlin_plonk_bindings.Types.Plonk_verifier_index.t
       [@@deriving bin_io_unversioned]
     end in
     method_ "toString"
       (fun this : Js.js_string Js.t ->
          Binable.to_string (module Backend.Verification_key) this##.value
        |> Js.string ) ;
  *)
  proof_class##.ofString :=
    Js.wrap_callback (fun (s : Js.js_string Js.t) : proof_class Js.t ->
        new%js proof_constr
          (Js.to_string s |> Binable.of_string (module Backend.Proof))) ;
  method_ "verify"
    (fun
      (this : verification_key_class Js.t)
      (pub : Js.Unsafe.any Js.js_array Js.t)
      (pi : proof_class Js.t)
      :
      bool Js.t
    ->
      let v = Backend.Field.Vector.create () in
      array_iter (Circuit.to_field_elts_magic pub) ~f:(fun x ->
          match x##.value with
          | Constant x ->
              Backend.Field.Vector.emplace_back v x
          | _ ->
              raise_error "verify: Expected non-circuit values for input") ;
      Backend.Proof.verify pi##.value this##.value v |> Js.bool)

let () =
  let method_ name (f : proof_class Js.t -> _) = method_ proof_class name f in
  method_ "toString" (fun this : Js.js_string Js.t ->
      Binable.to_string (module Backend.Proof) this##.value |> Js.string) ;
  proof_class##.ofString :=
    Js.wrap_callback (fun (s : Js.js_string Js.t) : proof_class Js.t ->
        new%js proof_constr
          (Js.to_string s |> Binable.of_string (module Backend.Proof))) ;
  method_ "verify"
    (fun
      (this : proof_class Js.t)
      (vk : verification_key_class Js.t)
      (pub : Js.Unsafe.any Js.js_array Js.t)
      :
      bool Js.t
    -> vk##verify pub this)

(* helpers for pickles_compile *)

module Single_field_statement = struct
  type t = Field.t

  let to_field_elements x = [| x |]
end

module Single_field_statement_const = struct
  type t = Field.Constant.t

  let to_field_elements x = [| x |]
end

type ('a_var, 'a_value, 'a_weird) pickles_rule =
  { identifier : string
  ; prevs : 'a_weird list
  ; main : 'a_var list -> 'a_var -> Boolean.var list
  ; main_value : 'a_value list -> 'a_value -> bool list
  }

type pickles_rule_js = Js.js_string Js.t * (field_class Js.t -> unit)

let create_pickles_rule ~self (identifier, main) =
  { identifier = Js.to_string identifier
  ; prevs = [ self ]
  ; main =
      (fun _ self ->
        main (to_js_field self) ;
        [ Boolean.false_ ])
  ; main_value = (fun _ _ -> [ false ])
  }

let pickles_compile (choices : pickles_rule_js Js.js_array Js.t) =
  console_log_string "pickles_compile" ;
  let choices = choices |> Js.to_array |> Array.to_list in
  let choices ~self =
    List.map choices ~f:(create_pickles_rule ~self) |> Obj.magic
  in
  let _tag, _cache, p, provers =
    Pickles.compile ~choices
      (module Single_field_statement)
      (module Single_field_statement_const)
      ~typ:Field.typ
      ~branches:(module Pickles_types.Nat.N1)
      ~max_branching:(module Pickles_types.Nat.N1)
      ~name:"smart-contract"
      ~constraint_constants:
        (* TODO these are dummy values *)
        { sub_windows_per_window = 0
        ; ledger_depth = 0
        ; work_delay = 0
        ; block_window_duration_ms = 0
        ; transaction_capacity = Log_2 0
        ; pending_coinbase_depth = 0
        ; coinbase_amount = Unsigned.UInt64.of_int 0
        ; supercharged_coinbase_factor = 0
        ; account_creation_fee = Unsigned.UInt64.of_int 0
        ; fork = None
        }
  in
  let module Proof = (val p) in
  object%js
    val provers = provers |> Obj.magic |> Array.of_list |> Js.array

    val getVerificationKey = fun () -> Lazy.force Proof.verification_key
  end

module Ledger = struct
  type js_field = field_class Js.t

  type js_uint32 = < value : js_field Js.readonly_prop > Js.t

  type js_uint64 = < value : js_field Js.readonly_prop > Js.t

  type 'a or_ignore =
    < check : bool_class Js.t Js.prop ; value : 'a Js.prop > Js.t

  type 'a set_or_keep =
    < set : bool_class Js.t Js.prop ; value : 'a Js.prop > Js.t

  type 'a closed_interval = < lower : 'a Js.prop ; upper : 'a Js.prop > Js.t

  type epoch_ledger_predicate =
    < hash : js_field or_ignore Js.prop
    ; totalCurrency : js_uint64 closed_interval Js.prop >
    Js.t

  type epoch_data_predicate =
    < ledger : epoch_ledger_predicate Js.prop
    ; seed : js_field or_ignore Js.prop
    ; startCheckpoint : js_field or_ignore Js.prop
    ; lockCheckpoint : js_field or_ignore Js.prop
    ; epochLength : js_uint32 closed_interval Js.prop >
    Js.t

  type protocol_state_predicate =
    < snarkedLedgerHash : js_field or_ignore Js.prop
    ; snarkedNextAvailableToken : js_uint64 closed_interval Js.prop
    ; timestamp : js_uint64 closed_interval Js.prop
    ; blockchainLength : js_uint32 closed_interval Js.prop
    ; minWindowDensity : js_uint32 closed_interval Js.prop
    ; lastVrfOutput : js_field or_ignore Js.prop
    ; totalCurrency : js_uint64 closed_interval Js.prop
    ; globalSlotSinceHardFork : js_uint32 closed_interval Js.prop
    ; globalSlotSinceGenesis : js_uint32 closed_interval Js.prop
    ; stakingEpochData : epoch_data_predicate Js.prop
    ; nextEpochData : epoch_data_predicate Js.prop >
    Js.t

  type public_key = < g : group_class Js.t Js.prop > Js.t

  type party_update =
    < appState : js_field set_or_keep Js.js_array Js.t Js.prop
    ; delegate : public_key set_or_keep Js.prop
    ; verificationKey : verification_key_class Js.t Js.prop >
    Js.t

  type js_int64 = < uint64Value : js_field Js.meth > Js.t

  type party_body =
    < publicKey : public_key Js.prop
    ; update : party_update Js.prop
    ; tokenId : js_uint64 Js.prop
    ; delta : js_int64 Js.prop
    ; events : js_field Js.js_array Js.t Js.js_array Js.t Js.prop
    ; sequenceEvents : js_field Js.js_array Js.t Js.js_array Js.t Js.prop
    ; callData : js_field Js.prop
    ; depth : int Js.prop >
    Js.t

  type full_account_predicate =
    < balance : js_uint64 closed_interval Js.prop
    ; nonce : js_uint32 closed_interval Js.prop
    ; receiptChainHash : js_field or_ignore Js.prop
    ; publicKey : public_key or_ignore Js.prop
    ; delegate : public_key or_ignore Js.prop
    ; state : js_field or_ignore Js.js_array Js.t Js.prop
    ; sequenceState : js_field or_ignore Js.prop
    ; provedState : bool_class Js.t or_ignore Js.prop >
    Js.t

  module Party_predicate = struct
    type party_predicate

    type t =
      < type_ : Js.js_string Js.t Js.prop ; value : party_predicate Js.prop >
      Js.t

    (*
type AccountPredicate =
  | { type: 'accept' }
  | { type: 'nonce', value: UInt32 }
  | { type: 'full', value: FullAccountPredicate }
   *)
  end

  type party =
    < body : party_body Js.prop ; predicate : Party_predicate.t Js.prop > Js.t

  type fee_payer_party =
    < body : party_body Js.prop ; predicate : js_uint32 Js.prop > Js.t

  type parties =
    < feePayer : fee_payer_party Js.prop
    ; otherParties : party Js.js_array Js.t Js.prop
    ; protocolState : protocol_state_predicate Js.prop >
    Js.t

  type snapp_account =
    < appState : js_field Js.js_array Js.t Js.readonly_prop > Js.t

  type account =
    < balance : js_uint64 Js.readonly_prop
    ; nonce : js_uint32 Js.readonly_prop
    ; snapp : snapp_account Js.readonly_prop >
    Js.t

  let ledger_class : < .. > Js.t =
    Js.Unsafe.eval_string {js|(function(v) { this.value = v; return this })|js}

  module L : Mina_base_kernel.Transaction_logic.Ledger_intf = struct
    module Account = Mina_base_kernel.Account
    module Account_id = Mina_base_kernel.Account_id
    module Transaction_logic = Mina_base_kernel.Transaction_logic
    module Ledger_hash = Mina_base_kernel.Ledger_hash
    module Token_id = Mina_base_kernel.Token_id

    type t_ =
      { next_location : int
      ; next_available_token : Token_id.t
      ; accounts : Account.t Int.Map.t
      ; locations : int Account_id.Map.t
      }

    type t = t_ ref

    type location = int

    let get (t : t) (loc : location) : Account.t option =
      Map.find !t.accounts loc

    let location_of_account (t : t) (a : Account_id.t) : location option =
      Map.find !t.locations a

    let set (t : t) (loc : location) (a : Account.t) : unit =
      t := { !t with accounts = Map.set !t.accounts ~key:loc ~data:a }

    let next_location (t : t) : int =
      let loc = !t.next_location in
      t := { !t with next_location = loc + 1 } ;
      loc

    let get_or_create (t : t) (id : Account_id.t) :
        (Transaction_logic.account_state * Account.t * location) Or_error.t =
      let loc = location_of_account t id in
      let res =
        match loc with
        | None ->
            let loc = next_location t in
            let a =
              { (Account.create id Currency.Balance.zero) with
                permissions = loose_permissions
              }
            in
            t := { !t with locations = Map.set !t.locations ~key:id ~data:loc } ;
            set t loc a ;
            (`Added, a, loc)
        | Some loc ->
            (`Existed, Option.value_exn (get t loc), loc)
      in
      Ok res

    let create_new_account (t : t) (id : Account_id.t) (a : Account.t) :
        unit Or_error.t =
      match location_of_account t id with
      | Some _ ->
          Or_error.errorf !"account %{sexp: Account_id.t} already present" id
      | None ->
          let loc = next_location t in
          t := { !t with locations = Map.set !t.locations ~key:id ~data:loc } ;
          set t loc a ;
          Ok ()

    let remove_accounts_exn (t : t) (ids : Account_id.t list) : unit =
      let locs = List.filter_map ids ~f:(fun id -> Map.find !t.locations id) in
      t :=
        { !t with
          locations = List.fold ids ~init:!t.locations ~f:Map.remove
        ; accounts = List.fold locs ~init:!t.accounts ~f:Map.remove
        }

    (* TODO *)
    let merkle_root (_ : t) : Ledger_hash.t = Field.Constant.zero

    let empty ~depth:_ () : t =
      ref
        { next_available_token = Token_id.(next default)
        ; next_location = 0
        ; accounts = Int.Map.empty
        ; locations = Account_id.Map.empty
        }

    let with_ledger (type a) ~depth ~(f : t -> a) : a = f (empty ~depth ())

    let next_available_token (t : t) = !t.next_available_token

    let set_next_available_token (t : t) (id : Token_id.t) : unit =
      t := { !t with next_available_token = id }

    let create_masked (t : t) : t = ref !t

    let apply_mask (t : t) ~(masked : t) = t := !masked
  end

  module T = Mina_base_kernel.Transaction_logic.Make (L)

  type ledger_class = < value : L.t Js.prop >

  let ledger_constr : (L.t -> ledger_class Js.t) Js.constr =
    Obj.magic ledger_class

  let create_new_account_exn (t : L.t) account_id account =
    L.create_new_account t account_id account |> Or_error.ok_exn

  module Snapp_predicate = Mina_base_kernel.Snapp_predicate
  module Party = Mina_base_kernel.Party
  module Snapp_state = Mina_base_kernel.Snapp_state
  module Token_id = Mina_base_kernel.Token_id

  let field (x : js_field) : Impl.field =
    match x##.value with Constant x -> x | x -> As_prover.read_var x

  let public_key (pk : public_key) : Signature_lib.Public_key.Compressed.t =
    { x = field pk##.g##.x
    ; is_odd = Bigint.(test_bit (of_field (field pk##.g##.y)) 0)
    }

  let uint32 (x : js_uint32) =
    Unsigned.UInt32.of_string (Field.Constant.to_string (field x##.value))

  let uint64 (x : js_uint64) =
    Unsigned.UInt64.of_string (Field.Constant.to_string (field x##.value))

  let int64 (x : js_int64) =
    let x =
      x##uint64Value |> field |> Field.Constant.to_string
      |> Unsigned.UInt64.of_string
      |> (fun x -> x)
      |> Unsigned.UInt64.to_int64
    in
    { Currency.Signed_poly.sgn =
        (if Int64.is_negative x then Sgn.Neg else Sgn.Pos)
    ; magnitude =
        Currency.Amount.of_uint64 (Unsigned.UInt64.of_int64 (Int64.abs x))
    }

  let or_ignore (type a) elt (x : a or_ignore) =
    if Js.to_bool x##.check##toBoolean then
      Mina_base_kernel.Snapp_basic.Or_ignore.Check (elt x##.value)
    else Ignore

  let closed_interval f (c : 'a closed_interval) :
      _ Snapp_predicate.Closed_interval.t =
    { lower = f c##.lower; upper = f c##.upper }

  let epoch_data (e : epoch_data_predicate) :
      Snapp_predicate.Protocol_state.Epoch_data.t =
    let ( ^ ) = Fn.compose in
    { ledger =
        { hash = or_ignore field e##.ledger##.hash
        ; total_currency =
            Check
              (closed_interval
                 (Currency.Amount.of_uint64 ^ uint64)
                 e##.ledger##.totalCurrency)
        }
    ; seed = or_ignore field e##.seed
    ; start_checkpoint = or_ignore field e##.startCheckpoint
    ; lock_checkpoint = or_ignore field e##.lockCheckpoint
    ; epoch_length =
        Check
          (closed_interval
             (Mina_numbers.Length.of_uint32 ^ uint32)
             e##.epochLength)
    }

  let protocol_state (p : protocol_state_predicate) :
      Snapp_predicate.Protocol_state.t =
    let ( ^ ) = Fn.compose in
    { snarked_ledger_hash = or_ignore field p##.snarkedLedgerHash
    ; snarked_next_available_token =
        Check
          (closed_interval
             (Token_id.of_uint64 ^ uint64)
             p##.snarkedNextAvailableToken)
    ; timestamp =
        Check
          (closed_interval
             (fun x ->
               field x##.value
               |> Field.Constant.to_string |> Unsigned.UInt64.of_string
               |> Block_time.of_uint64)
             p##.timestamp)
    ; blockchain_length =
        Check
          (closed_interval
             (Mina_numbers.Length.of_uint32 ^ uint32)
             p##.blockchainLength)
    ; min_window_density =
        Check
          (closed_interval
             (Mina_numbers.Length.of_uint32 ^ uint32)
             p##.minWindowDensity)
    ; last_vrf_output = ()
    ; total_currency =
        Check
          (closed_interval
             (Currency.Amount.of_uint64 ^ uint64)
             p##.totalCurrency)
    ; global_slot_since_hard_fork =
        Check
          (closed_interval
             (Mina_numbers.Global_slot.of_uint32 ^ uint32)
             p##.globalSlotSinceHardFork)
    ; global_slot_since_genesis =
        Check
          (closed_interval
             (Mina_numbers.Global_slot.of_uint32 ^ uint32)
             p##.globalSlotSinceGenesis)
    ; staking_epoch_data = epoch_data p##.stakingEpochData
    ; next_epoch_data = epoch_data p##.nextEpochData
    }

  let set_or_keep (type a) elt (x : a set_or_keep) =
    if Js.to_bool x##.set##toBoolean then
      Mina_base_kernel.Snapp_basic.Set_or_keep.Set (elt x##.value)
    else Keep

  let body (b : party_body) : Party.Body.t =
    let update : Party.Update.t =
      let u = b##.update in

      { Party.Update.Poly.app_state =
          Pickles_types.Vector.init Snapp_state.Max_state_size.n ~f:(fun i ->
              set_or_keep field (array_get_exn u##.appState i))
      ; delegate = set_or_keep public_key u##.delegate
      ; verification_key = (* TODO *)
                           Keep
      ; permissions = Keep
      ; snapp_uri = Keep
      ; token_symbol = Keep
      ; timing = Keep
      }
    in

    { pk = public_key b##.publicKey
    ; update
    ; token_id = Token_id.of_uint64 (uint64 b##.tokenId)
    ; delta = int64 b##.delta
    ; events =
        Array.map
          (Js.to_array b##.events)
          ~f:(fun a -> Array.map (Js.to_array a) ~f:field)
        |> Array.to_list
    ; sequence_events =
        Array.map
          (Js.to_array b##.sequenceEvents)
          ~f:(fun a -> Array.map (Js.to_array a) ~f:field)
        |> Array.to_list
    ; call_data = field b##.callData
    ; depth = b##.depth
    }

  let fee_payer_party (party : fee_payer_party) : Party.Predicated.Fee_payer.t =
    let b = body party##.body in
    { body =
        { b with
          token_id = ()
        ; delta = Currency.Amount.to_fee b.delta.magnitude
        }
    ; predicate =
        uint32 party##.predicate |> Mina_numbers.Account_nonce.of_uint32
    }

  let predicate (t : Party_predicate.t) : Mina_base_kernel.Party.Predicate.t =
    match Js.to_string t##.type_ with
    | "accept" ->
        Accept
    | "nonce" ->
        Nonce
          (Mina_numbers.Account_nonce.of_uint32
             (uint32 (Obj.magic t##.value : js_uint32)))
    | "full" ->
        let p : full_account_predicate = Obj.magic t##.value in
        Full
          { balance =
              Check
                (closed_interval
                   (Fn.compose Currency.Balance.of_uint64 uint64)
                   p##.balance)
          ; nonce =
              Check
                (closed_interval
                   (Fn.compose Mina_numbers.Account_nonce.of_uint32 uint32)
                   p##.nonce)
          ; receipt_chain_hash = or_ignore field p##.receiptChainHash
          ; public_key = or_ignore public_key p##.publicKey
          ; delegate = or_ignore public_key p##.delegate
          ; state =
              Pickles_types.Vector.init Snapp_state.Max_state_size.n
                ~f:(fun i -> or_ignore field (array_get_exn p##.state i))
          ; sequence_state = or_ignore field p##.sequenceState
          ; proved_state =
              or_ignore (fun x -> Js.to_bool x##toBoolean) p##.provedState
          }
    | s ->
        failwithf "bad predicate type: %s" s ()

  let party (party : party) : Party.Predicated.t =
    { body = body party##.body; predicate = predicate party##.predicate }

  let parties (parties : parties) : Mina_base_kernel.Parties.t =
    { fee_payer =
        { data = fee_payer_party parties##.feePayer
        ; authorization = Mina_base_kernel.Signature.dummy
        }
    ; other_parties =
        Js.to_array parties##.otherParties
        |> Array.map ~f:(fun p : Party.t ->
               { data = party p; authorization = None_given })
        |> Array.to_list
    ; protocol_state = protocol_state parties##.protocolState
    ; memo = Mina_base_kernel.Signed_command_memo.empty
    }

  let account_id pk =
    Mina_base_kernel.Account_id.create (public_key pk) Token_id.default

  let max_state_size = Pickles_types.Nat.to_int Snapp_state.Max_state_size.n

  let () =
    let static_method name f =
      Js.Unsafe.set ledger_class (Js.string name) (Js.wrap_callback f)
    in
    let method_ name (f : ledger_class Js.t -> _) =
      method_ ledger_class name f
    in
    let add_account_exn (l : L.t) pk balance =
      let account_id = account_id pk in

      let bal_u64 =
        (* TODO: Why is this conversion necessary to make it work ? *)
        Unsigned.UInt64.of_string (Int.to_string balance)
      in

      let balance = Currency.Balance.of_uint64 bal_u64 in

      let a : Mina_base_kernel.Account.t =
        { (Mina_base_kernel.Account.create account_id balance) with
          permissions = loose_permissions
        }
      in

      create_new_account_exn l account_id a
    in
    let create
        (genesis_accounts :
          < publicKey : public_key Js.prop ; balance : int Js.prop > Js.t
          Js.js_array
          Js.t) : ledger_class Js.t =
      let l = L.empty ~depth:20 () in
      array_iter genesis_accounts ~f:(fun a ->
          add_account_exn l a##.publicKey a##.balance) ;
      new%js ledger_constr l
    in
    static_method "create" create ;
    let epoch_data =
      { Snapp_predicate.Protocol_state.Epoch_data.Poly.ledger =
          { Mina_base_kernel.Epoch_ledger.Poly.hash = Field.Constant.zero
          ; total_currency = Currency.Amount.zero
          }
      ; seed = Field.Constant.zero
      ; start_checkpoint = Field.Constant.zero
      ; lock_checkpoint = Field.Constant.zero
      ; epoch_length = Mina_numbers.Length.zero
      }
    in
    method_ "getAccount" (fun l (pk : public_key) : account Js.opt ->
        match
          Option.bind
            (L.location_of_account l##.value (account_id pk))
            ~f:(L.get l##.value)
        with
        | None ->
            Js.Opt.empty
        | Some a ->
            let mk x : field_class Js.t =
              new%js field_constr (As_field.of_field x)
            in

            let uint64 n =
              object%js
                val value =
                  Unsigned.UInt64.to_string n
                  |> Field.Constant.of_string |> Field.constant |> mk
              end
            in
            let uint32 n =
              object%js
                val value =
                  Unsigned.UInt32.to_string n
                  |> Field.Constant.of_string |> Field.constant |> mk
              end
            in
            let app_state =
              let xs = new%js Js.array_empty in
              ( match a.snapp with
              | Some s ->
                  Pickles_types.Vector.iter s.app_state ~f:(fun x ->
                      ignore (xs##push (mk (Field.constant x))))
              | None ->
                  for _ = 0 to max_state_size - 1 do
                    xs##push (mk Field.zero) |> ignore
                  done ) ;
              xs
            in
            Js.Opt.return
              (object%js
                 val balance = uint64 (Currency.Balance.to_uint64 a.balance)

                 val nonce =
                   uint32 (Mina_numbers.Account_nonce.to_uint32 a.nonce)

                 val snapp =
                   object%js
                     val appState = app_state
                   end
              end)) ;
    method_ "addAccount" (fun l (pk : public_key) (balance : int) ->
        add_account_exn l##.value pk balance) ;
    method_ "applyPartiesTransaction" (fun l (p : parties) : unit ->
        T.apply_transaction l##.value
          ~constraint_constants:Genesis_constants.Constraint_constants.compiled
          ~txn_state_view:
            { snarked_ledger_hash = Field.Constant.zero
            ; snarked_next_available_token = Token_id.(next default)
            ; timestamp = Block_time.zero
            ; blockchain_length = Mina_numbers.Length.zero
            ; min_window_density = Mina_numbers.Length.zero
            ; last_vrf_output = ()
            ; total_currency = Currency.Amount.zero
            ; global_slot_since_hard_fork = Mina_numbers.Global_slot.zero
            ; global_slot_since_genesis = Mina_numbers.Global_slot.zero
            ; staking_epoch_data = epoch_data
            ; next_epoch_data = epoch_data
            }
          (Command (Parties (parties p)))
        |> Or_error.ok_exn |> ignore) ;
    ()

  (*
export class Ledger {
  static create(genesisAccounts: Array<{publicKey: PublicKey, balance: number}>): Ledger;

  applyPartiesTransaction(parties: Parties);

  getAccount(publicKey: PublicKey): Account | null;
};
*)
end

let export () =
  Js.export "Field" field_class ;
  Js.export "Scalar" scalar_class ;
  Js.export "Bool" bool_class ;
  Js.export "Group" group_class ;
  Js.export "Poseidon" poseidon ;
  Js.export "Circuit" Circuit.circuit ;
  Js.export "Ledger" Ledger.ledger_class ;
  (* TODO: should we use Js.wrap_callback here? *)
  Js.export "picklesCompile" pickles_compile

let export_global () =
  let snarky_obj =
    Js.Unsafe.(
      let i = inject in
      obj
        [| ("Field", i field_class)
         ; ("Scalar", i scalar_class)
         ; ("Bool", i bool_class)
         ; ("Group", i group_class)
         ; ("Poseidon", i poseidon)
         ; ("Circuit", i Circuit.circuit)
         ; ("Ledger", i Ledger.ledger_class)
        |])
  in
  Js.Unsafe.(set global (Js.string "__snarky") snarky_obj)
