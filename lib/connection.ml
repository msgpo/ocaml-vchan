(*
 * Copyright (c) 2013 Citrix Systems Inc
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)
open S
open Sexplib.Std
open Lwt

external (|>) : 'a -> ('a -> 'b) -> 'b = "%revapply";;
external ( $ ) : ('a -> 'b) -> 'a -> 'b = "%apply"

let ( >>= ) = Lwt.bind

let i_int (i:int) = ignore i

module Int32 = struct
  include Int32

  let ( - ) = Int32.sub
  let ( + ) = Int32.add
end

module Opt = struct
  let map f o = match o with Some e -> Some (f e) | None -> None
  let iter f o = match o with Some e -> f e | None -> ()
end

(* GCC atomic stuff *)

external atomic_or_fetch : Cstruct.buffer -> int -> int -> int = "stub_atomic_or_fetch_uint8"
external atomic_fetch_and : Cstruct.buffer -> int -> int -> int = "stub_atomic_fetch_and_uint8"

(* left is client write, server read
   right is client read, server write *)

(* XXX: the xen headers do not use __attribute__(packed). Edit vb: Was
   OK for me. *)

(* matches xen/include/public/io/libxenvchan.h:ring_shared *)
cstruct ring_shared {
  uint32_t cons;
  uint32_t prod
} as little_endian

(* matches xen/include/public/io/libxenvchan.h:vchan_interface *)
cstruct vchan_interface {
  uint8_t left[8];  (* ring_shared *)
  uint8_t right[8]; (* ring_shared *)
  uint16_t left_order;
  uint16_t right_order;
  uint8_t cli_live;
  uint8_t srv_live;
  uint8_t cli_notify;
  uint8_t srv_notify
} as little_endian

let get_ro v = get_vchan_interface_right_order v
let get_lo v = get_vchan_interface_left_order v
let get_lp v = get_ring_shared_prod (get_vchan_interface_left v)
let set_lp v = set_ring_shared_prod (get_vchan_interface_left v)
let get_rp v = get_ring_shared_prod (get_vchan_interface_right v)
let set_rp v = set_ring_shared_prod (get_vchan_interface_right v)
let get_lc v = get_ring_shared_cons (get_vchan_interface_left v)
let set_lc v = set_ring_shared_cons (get_vchan_interface_left v)
let get_rc v = get_ring_shared_cons (get_vchan_interface_right v)
let set_rc v = set_ring_shared_cons (get_vchan_interface_right v)

type ('a, 'b) result =
  | Ok of 'a
  | Error of 'b

type buffer_location =
  | Offset1024      (* 1024-byte ring at offset 1024 in shared page *)
  | Offset2048      (* 2048-byte ring at offset 2048 in shared page *)
  | External of int (* 2 ^^ x pages in use *)
with sexp

let length_available_at_buffer_location = function
  | Offset1024 -> 1024
  | Offset2048 -> 2048
  | External x -> 1 lsl (x + 12)

(* Any more than (External 8) will generate too many grants to fit
   in the page, if both sides attempt it. *)
let max_buffer_location = External 8

let legal_buffer_locations = [
    Offset1024; Offset2048;
    External 0; External 1; External 2; External 3; External 4;
    External 5; External 6; External 7; External 8
]

let buffer_location_of_order = function
  | 10 -> Ok Offset1024
  | 11 -> Ok Offset2048
  | n when n >= 12 -> Ok (External (n - 12))
  | x -> Error (`Bad_order x)

let order_of_buffer_location = function
  | Offset1024 -> 10
  | Offset2048 -> 11
  | External n -> n + 12

type read_write = Read | Write

let bit_of_read_write = function Read -> 2 | Write -> 1

module Make(E : EVENTS)(M: MEMORY)(C: CONFIGURATION) = struct

type server_params =
  {
    shr_shr: M.share;
    read_shr: M.share option;
    write_shr: M.share option
  }
with sexp_of

type client_params =
  {
    shr_map: M.mapping;
    read_map: M.mapping option;
    write_map: M.mapping option
  }
with sexp_of

(* Vchan peers are explicitly client or servers *)
type role =
  (* true if we allow reconnection *)
  | Server of server_params
  | Client of client_params
with sexp_of

(* The state of a single vchan peer *)
type t = {
  remote_domid: int;
  remote_port: Port.t;
  shared_page: Cstruct.t; (* the shared metadata *)
  role: role;
  read: Cstruct.t; (* the ring where you read data from *)
  write: Cstruct.t; (* the ring where you write data to *)
  evtchn: E.channel; (* Event channel to notify the other end *)
  mutable token: E.event;
  mutable ack_up_to: int; (* FLOW reader has seen this much data *)
}

type state =
  | Exited
  | Connected
  | WaitingForConnection
with sexp

type error = [
  `Unknown of string
]

type flow = t
type 'a io = 'a Lwt.t
type buffer = Cstruct.t

let state_of_live = function
  | 0 -> Ok Exited
  | 1 -> Ok Connected
  | 2 -> Ok WaitingForConnection
  | n -> Error (`Bad_live n)

let live_of_state = function
  | Exited -> 0
  | Connected -> 1
  | WaitingForConnection -> 2

let rd_prod vch = match vch.role with
  | Client _ -> get_rp vch.shared_page
  | Server _ -> get_lp vch.shared_page

let rd_cons vch = match vch.role with
  | Client _ -> get_rc vch.shared_page
  | Server _ -> get_lc vch.shared_page

let set_rd_cons vch = match vch.role with
  | Client _ -> set_rc vch.shared_page
  | Server _ -> set_lc vch.shared_page

let wr_prod vch = match vch.role with
  | Client _ -> get_lp vch.shared_page
  | Server _ -> get_rp vch.shared_page

let set_wr_prod vch v = match vch.role with
  | Client _ -> set_lp vch.shared_page v
  | Server _ -> set_rp vch.shared_page v

let wr_cons vch = match vch.role with
  | Client _ -> get_lc vch.shared_page
  | Server _ -> get_rc vch.shared_page

let wr_ring_size vch = match vch.role with
  | Client _ -> 1 lsl get_lo vch.shared_page
  | Server _ -> 1 lsl get_ro vch.shared_page

let rd_ring_size vch = match vch.role with
  | Client _ -> 1 lsl get_ro vch.shared_page
  | Server _ -> 1 lsl get_lo vch.shared_page

(* A convenient wrapper to enhance the pretty-printing *)
type printable_t = {
  role: role;
  left_order: buffer_location option;
  right_order: buffer_location option;
  remote_domid: int;
  remote_port: Port.t;
  client_state: state option;
  server_state: state option;
  read_producer: int32;
  read_consumer: int32;
  read: string;
  write_producer: int32;
  write_consumer: int32;
  write: string;
  ack_up_to: int;
} with sexp_of

let sexp_of_t (t: t) =
  let role = t.role in
  let client_state =
    match state_of_live (get_vchan_interface_cli_live t.shared_page)
    with Ok st -> Some st | _ -> None in
  let server_state =
    match state_of_live (get_vchan_interface_srv_live t.shared_page)
    with Ok st -> Some st | _ -> None in
  let left_order =
    match buffer_location_of_order (get_vchan_interface_left_order t.shared_page)
    with Ok x -> Some x | _ -> None in
  let right_order =
    match buffer_location_of_order (get_vchan_interface_right_order t.shared_page)
    with Ok x -> Some x | _ -> None in
  let read_producer = rd_prod t in
  let read_consumer = rd_cons t in
  let read = Cstruct.to_string t.read in
  let write_producer = wr_prod t in
  let write_consumer = wr_cons t in
  let write = Cstruct.to_string t.write in
  let remote_domid = t.remote_domid in
  let remote_port = t.remote_port in
  let ack_up_to = t.ack_up_to in
  let printable_t = {
    role; left_order; right_order;
    client_state; server_state; read_producer; read_consumer; read;
    write_producer; write_consumer; write; remote_domid; remote_port;
    ack_up_to;
  } in
  sexp_of_printable_t printable_t

(* Request notify to the other endpoint. If client, request to server,
   and vice versa. *)
let request_notify (vch: t) rdwr =
  let open Cstruct in
  (* This should be correct: client -> srv_notify | server -> cli_notify *)
  let idx = match vch.role with Client _ -> 23 | Server _ -> 22 in
  i_int (atomic_or_fetch vch.shared_page.buffer idx (bit_of_read_write rdwr))
  (*; Xenctrl.xen_mb ()*)

let send_notify (vch: t) rdwr =
  let open Cstruct in
  (*Xenctrl.xen_mb ();*)
  (* This should be correct: client -> cli_notify | server -> srv_notify *)
  let idx = match vch.role with Client _ -> 22 | Server _ -> 23 in
  let bit = bit_of_read_write rdwr in
  let prev =
    (* clear the bit and return previous value *)
    atomic_fetch_and vch.shared_page.buffer idx (lnot bit) in
  if prev land bit <> 0 then E.send vch.evtchn

let fast_get_data_ready (vch: t) request =
  let ready = Int32.(rd_prod vch - rd_cons vch |> to_int) in
  if ready >= request then ready else
    (request_notify vch Write; Int32.(rd_prod vch - rd_cons vch |> to_int))

let data_ready (vch: t) =
  request_notify vch Write;
  Int32.(rd_prod vch - rd_cons vch |> to_int)

let fast_get_buffer_space (vch: t) request =
  let ready = wr_ring_size vch - Int32.(wr_prod vch - wr_cons vch |> to_int) in
  if ready > request then ready else
    (
      request_notify vch Read;
      wr_ring_size vch - Int32.(wr_prod vch - wr_cons vch |> to_int)
    )

let buffer_space (vch: t) =
  request_notify vch Read;
  wr_ring_size vch - Int32.(wr_prod vch - wr_cons vch |> to_int)

let state vch =
  let client_state =
    match state_of_live (get_vchan_interface_cli_live vch.shared_page)
    with Ok st -> st | _ -> raise (Invalid_argument "cli_live")
  and server_state =
    match state_of_live (get_vchan_interface_srv_live vch.shared_page)
    with Ok st -> st | _ -> raise (Invalid_argument "srv_live") in
  match vch.role with
  | Server _ -> client_state
  | Client _ -> server_state

(* Write as much data as we can without blocking *)
let _write_noblock vch buf =
  let len = Cstruct.len buf in
  let real_idx = Int32.(logand (wr_prod vch) (of_int (wr_ring_size vch) - 1l) |> to_int) in
  let avail_contig = wr_ring_size vch - real_idx in
  let avail_contig = if avail_contig > len then len else avail_contig in
  (*Xenctrl.xen_mb ();*)
  Cstruct.blit buf 0 vch.write real_idx avail_contig;
  (if avail_contig < len then (* We rolled across the end of the ring *)
    Cstruct.blit buf avail_contig vch.write 0 (len - avail_contig));
  (*Xenctrl.xen_wmb ();*)
  set_wr_prod vch Int32.(wr_prod vch + of_int len);
  send_notify vch Write

(* Write a whole buffer in a blocking fashion *)
let write vch buf =
  let len = Cstruct.len buf in
  let rec inner pos event =
    if state vch <> Connected
    then Lwt.return `Eof
    else
      let avail = min (fast_get_buffer_space vch (len - pos)) (len - pos) in
      if avail > 0 then _write_noblock vch (Cstruct.sub buf pos avail);
      let pos = pos + avail in
      if pos = len
      then Lwt.return (`Ok ())
      else E.recv vch.evtchn event >>= fun event -> inner pos event
  in inner 0 E.initial

let rec writev vch = function
| [] -> Lwt.return (`Ok ())
| b :: bs ->
  write vch b >>= function
  | `Ok () -> writev vch bs
  | `Eof -> Lwt.return `Eof
  | `Error m -> Lwt.return (`Error m)

(* Read a chunk in a blocking fashion. Note this returns a
   reference to the data in the ring. *)
let rec _read_one vch event =
  (* wait until at least 1 byte is available or the connection has closed *)
  let avail = fast_get_data_ready vch 1 in
  let state = state vch in
  if avail = 0 && state = Connected
  then E.recv vch.evtchn event >>= fun event -> _read_one vch event
  else
    if avail = 0 && state <> Connected
    then Lwt.return `Eof
    else
      let real_idx = Int32.(logand (rd_cons vch) (of_int (rd_ring_size vch) - 1l) |> to_int) in
      let bytes_before_wraparound = rd_ring_size vch - real_idx in
      let buf =
        if bytes_before_wraparound = 0 then begin
          (* all bytes are in a contiguous block starting at 0 *)
          Cstruct.sub vch.read 0 avail
        end else begin
          (* we'll only consume the bytes before wraparound on this iteration *)
          Cstruct.sub vch.read real_idx (min avail bytes_before_wraparound)
        end in
      Lwt.return (`Ok buf)

let read vch =
  (* signal the remote that we've consumed the last block of data it sent us *)
  set_rd_cons vch Int32.(of_int vch.ack_up_to);
  send_notify vch Read;
  (* get the fresh data *)
  _read_one vch E.initial >>= function
  | `Ok buf ->
    (* we'll signal the remote we've consumed this data on the next iteration *)
    vch.ack_up_to <- vch.ack_up_to + (Cstruct.len buf);
    Lwt.return (`Ok buf)
  | `Eof -> Lwt.return `Eof
  | `Error m -> Lwt.return (`Error m)

let server ~domid ~port ~read_size ~write_size =
  (* The vchan convention is that the 'server' allocates and
     shares the pages with the 'client'. Note this is the
     reverse of the xen block protocol where the frontend
     (ie the 'client') shares pages with the backend (the
     'server') If we were to re-implement the block protocol
     over vchan, we should therefore make the frontend into
     the 'server' *)

  (* Allocate and initialise the shared page *)
  let shr_shr = M.share ~domid ~npages:1 ~rw:true in
  let v = Cstruct.of_bigarray (M.buf_of_share shr_shr) in
  set_lc v 0l;
  set_lp v 0l;
  set_rc v 0l;
  set_lc v 0l;
  set_vchan_interface_cli_live v (live_of_state WaitingForConnection);
  set_vchan_interface_srv_live v (live_of_state Connected);
  set_vchan_interface_cli_notify v (bit_of_read_write Write);
  set_vchan_interface_srv_notify v 0;

  (* Initialise the payload buffers *)
  let suitable_locations requested_size =
    let locs = List.filter
      (fun bl -> length_available_at_buffer_location bl >= requested_size)
      legal_buffer_locations in
    match locs with
      | []     -> max_buffer_location
      | h::t   -> h in
  (* Use the smallest amount of buffer space for read and write buffers.
     Since each of 'Offset1024' and 'Offset2048' refer to slots in the original shared page,
     read or write may use them but not both at once. If the requested size
     is very large, we'll use our maximum amount of buffer space rather than fail. *)
  let read_l, write_l = match suitable_locations read_size, suitable_locations write_size with
  (* avoid clashes for the slots in the original page *)
  | Offset1024, Offset1024 -> Offset1024, Offset2048
  | Offset2048, Offset1024 -> Offset2048, Offset1024
  | Offset1024, Offset2048 -> Offset1024, Offset2048
  | Offset2048, Offset2048 -> Offset2048, External 0
  | n                      -> n in

  set_vchan_interface_left_order v (order_of_buffer_location read_l);
  set_vchan_interface_right_order v (order_of_buffer_location write_l);

  let allocate_buffer_locations = function
  | Offset1024 -> None, Cstruct.sub v 1024 (length_available_at_buffer_location Offset1024)
  | Offset2048 -> None, Cstruct.sub v 2048 (length_available_at_buffer_location Offset2048)
  | External n ->
    let share = M.share ~domid ~npages:(1 lsl n) ~rw:true in
    let pages = M.buf_of_share share in
    Some share, Cstruct.of_bigarray pages in

  let read_shr, read_buf = allocate_buffer_locations read_l in
  let write_shr, write_buf = allocate_buffer_locations write_l in
  let nb_read_pages = match read_shr with None -> 0 | Some shr -> List.length (M.grants_of_share shr) in

  (* Write the gntrefs to the shared page. Ordering is left, right. *)
  List.iteri
    (fun i ref ->
       Cstruct.LE.set_uint32 v (sizeof_vchan_interface+i*4) (M.int32_of_grant ref))
    (match read_shr with None -> [] | Some shr -> M.grants_of_share shr);

  List.iteri
    (fun i ref ->
       Cstruct.LE.set_uint32 v (sizeof_vchan_interface+(i+nb_read_pages)*4)
         (M.int32_of_grant ref))
    (match write_shr with None -> [] | Some shr -> M.grants_of_share shr);

  (* Allocate the event channel *)
  let unbound_port, evtchn = E.listen domid in

  (* Write the config to XenStore *)
  let ring_ref = M.grants_of_share shr_shr |> List.hd |> M.int32_of_grant |> Int32.to_string in

  C.write ~client_domid:domid ~port { C.ring_ref; event_channel = E.string_of_port unbound_port }
  >>= fun () -> 

  let role = Server { shr_shr; read_shr; write_shr } in
  let ack_up_to = 0 in
  let remote_port = port and remote_domid = domid in
  let vch = { remote_port; remote_domid; shared_page=v; role;
              read=read_buf; write=write_buf; evtchn;
              token=E.initial; ack_up_to } in
  (* Wait for the connection *)
  let rec loop event =
    if state vch = WaitingForConnection then begin
      E.recv evtchn event >>= fun event -> 
      loop event
    end else return () in
  loop E.initial
  >>= fun () ->

  return vch

let client ~domid ~port =
  C.read ~server_domid:domid ~port
  >>= fun { C.ring_ref = gntref; event_channel = evtchn } ->
  let gntref = int_of_string gntref in
  (match E.port_of_string evtchn with
   | `Ok x -> return x
   | `Error m -> fail (Failure m)
  ) >>= fun unbound_port ->
 
  (* Map the vchan interface page *)
  let mapping = M.map ~domid ~grant:(M.grant_of_int32 (Int32.of_int gntref)) ~rw:true in
  let vchan_intf_cstruct = Cstruct.of_bigarray (M.buf_of_mapping mapping) in

  (* Resizing vchan_intf_cstruct *)
  let nb_left_pages = 1 lsl (get_lo vchan_intf_cstruct - 12) in
  let nb_right_pages = 1 lsl (get_ro vchan_intf_cstruct - 12) in
  let vchan_intf_cstruct = Cstruct.sub vchan_intf_cstruct 0
      (sizeof_vchan_interface+4*(nb_left_pages+nb_right_pages)) in

  (* Set initial values in vchan_intf *)
  set_vchan_interface_cli_live vchan_intf_cstruct (live_of_state Connected);
  set_vchan_interface_srv_notify vchan_intf_cstruct (bit_of_read_write Write);

  (* Bind the event channel *)
  let evtchn = E.connect domid unbound_port in

  (* Map the rings *)
  let rings_of_vchan_intf v =
    let lo = get_lo v in
    let ro = get_ro v in
    match lo, ro with
      | 10, 10 -> (None, Cstruct.sub v 1024 1024), (None, Cstruct.sub v 2048 1024)
      | 10, 11 -> (None, Cstruct.sub v 1024 1024), (None, Cstruct.sub v 2048 2048)
      | 11, 10 -> (None, Cstruct.sub v 2048 2048), (None, Cstruct.sub v 1024 1024)
      | 11, 11 ->
        let gntref =
          (Cstruct.LE.get_uint32 vchan_intf_cstruct sizeof_vchan_interface |> Int32.to_int) in
        let mapping = M.map ~domid ~grant:(M.grant_of_int32 (Int32.of_int gntref)) ~rw:true in
        (None, Cstruct.sub v 2048 2048),
        (Some mapping, Cstruct.of_bigarray (M.buf_of_mapping mapping))

      | n, m when n > 9 && m > 9 ->
        let lgrants = Array.make nb_left_pages 0 in
        let rgrants = Array.make nb_right_pages 0 in

        (* Reading grant refs from the shared page and load them into
           the arrays just created. *)
        let lgrants =
          for i = 0 to nb_left_pages - 1 do
            lgrants.(i) <- Cstruct.LE.get_uint32 vchan_intf_cstruct
                (sizeof_vchan_interface + i*4) |> Int32.to_int
          done;
          List.map (fun ref -> domid, M.grant_of_int32 (Int32.of_int ref))
            (Array.to_list lgrants) in
        let rgrants =
          for i = 0 to nb_right_pages - 1 do
            rgrants.(i) <- Cstruct.LE.get_uint32 vchan_intf_cstruct
                (sizeof_vchan_interface + nb_left_pages*4 + i*4) |> Int32.to_int
          done;
          List.map (fun ref -> domid, M.grant_of_int32 (Int32.of_int ref))
            (Array.to_list rgrants) in

        (* Use the grant refs arrays to map left and right pages. *)
        let lgrants_map =
          let mapping = M.mapv ~grants:lgrants ~rw:true in
          (Some mapping, Cstruct.of_bigarray (M.buf_of_mapping mapping)) in

        let rgrants_map =
          let mapping = M.mapv ~grants:rgrants ~rw:true in
          (Some mapping, Cstruct.of_bigarray (M.buf_of_mapping mapping)) in
        lgrants_map, rgrants_map

      | n, m -> failwith (Printf.sprintf "Invalid orders: left = %d, right = %d" lo ro) in

  let (w_map, w_buf), (r_map, r_buf) = rings_of_vchan_intf vchan_intf_cstruct in

  (* Signal the server so it knows we have connected *)
  E.send evtchn;

  let role = Client { shr_map=mapping; read_map=r_map; write_map=w_map } in
  let ack_up_to = 0 in
  let remote_port = port and remote_domid = domid in
  Lwt.return { remote_port; remote_domid; shared_page=vchan_intf_cstruct; role; read=r_buf; write=w_buf; evtchn; token=E.initial; ack_up_to }

let close (vch: t) =
  match vch.role with
  | Client { shr_map; read_map; write_map } ->
    set_vchan_interface_cli_live vch.shared_page (live_of_state Exited);
    E.send vch.evtchn;

    Opt.iter M.unmap read_map;
    Opt.iter M.unmap write_map;
    M.unmap shr_map;
    return ()

  | Server { shr_shr; read_shr; write_shr } ->
    set_vchan_interface_srv_live vch.shared_page (live_of_state Exited);
    E.send vch.evtchn;

    (* Remove the advertising in xenstore *)
    C.delete ~client_domid:vch.remote_domid ~port:vch.remote_port
    >>= fun () ->

    Opt.iter M.unshare read_shr;
    Opt.iter M.unshare write_shr;
    M.unshare shr_shr;
    return ()

end