%%--------------------------------------------------------------------
%% Copyright (c) 2013-2018 EMQ Inc. All rights reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_packet).

-include("emqx.hrl").

-include("emqx_mqtt.hrl").

-export([protocol_name/1, type_name/1, connack_name/1]).

-export([format/1]).

-export([to_message/1, from_message/1]).

%% @doc Protocol name of version
-spec(protocol_name(mqtt_vsn()) -> binary()).
protocol_name(?MQTT_PROTO_V3) -> <<"MQIsdp">>;
protocol_name(?MQTT_PROTO_V4) -> <<"MQTT">>;
protocol_name(?MQTT_PROTO_V5) -> <<"MQTT">>.

%% @doc Name of MQTT packet type
-spec(type_name(mqtt_packet_type()) -> atom()).
type_name(Type) when Type > ?RESERVED andalso Type =< ?AUTH ->
    lists:nth(Type, ?TYPE_NAMES).

%% @doc Connack Name
-spec(connack_name(mqtt_connack()) -> atom()).
connack_name(?CONNACK_ACCEPT)      -> 'CONNACK_ACCEPT';
connack_name(?CONNACK_PROTO_VER)   -> 'CONNACK_PROTO_VER';
connack_name(?CONNACK_INVALID_ID)  -> 'CONNACK_INVALID_ID';
connack_name(?CONNACK_SERVER)      -> 'CONNACK_SERVER';
connack_name(?CONNACK_CREDENTIALS) -> 'CONNACK_CREDENTIALS';
connack_name(?CONNACK_AUTH)        -> 'CONNACK_AUTH'.

%% @doc From Message to Packet
-spec(from_message(message()) -> mqtt_packet()).
from_message(Msg = #message{qos     = Qos,
                            topic   = Topic,
                            payload = Payload}) ->
    Dup = emqx_message:get_flag(dup, Msg, false),
    Retain = emqx_message:get_flag(retain, Msg, false),
    PacketId = emqx_message:get_header(packet_id, Msg),
    #mqtt_packet{header = #mqtt_packet_header{type   = ?PUBLISH,
                                              qos    = Qos,
                                              retain = Retain,
                                              dup    = Dup},
                 variable = #mqtt_packet_publish{topic_name = Topic,
                                                 packet_id  = PacketId},
                 payload = Payload}.

%% @doc Message from Packet
-spec(to_message(mqtt_packet()) -> message()).
to_message(#mqtt_packet{header   = #mqtt_packet_header{type   = ?PUBLISH,
                                                       retain = Retain,
                                                       qos    = Qos,
                                                       dup    = Dup}, 
                        variable = #mqtt_packet_publish{topic_name = Topic,
                                                        packet_id  = PacketId,
                                                        properties = Props},
                        payload  = Payload}) ->
    Msg = emqx_message:make(undefined, Topic, Payload),
    Msg#message{qos        = Qos,
                flags      = #{dup => Dup, retain => Retain},
                headers    = #{packet_id => PacketId},
                properties = Props};
to_message(#mqtt_packet_connect{will_flag = false}) ->
    undefined;
to_message(#mqtt_packet_connect{will_retain = Retain,
                                will_qos    = Qos,
                                will_topic  = Topic,
                                will_props  = Props,
                                will_msg    = Payload}) ->
    Msg = emqx_message:make(undefined, Topic, Payload),
    Msg#message{flags      = #{retain => Retain},
                headers    = #{qos => Qos},
                properties = Props}.

%% @doc Format packet
-spec(format(mqtt_packet()) -> iolist()).
format(#mqtt_packet{header = Header, variable = Variable, payload = Payload}) ->
    format_header(Header, format_variable(Variable, Payload)).

format_header(#mqtt_packet_header{type = Type,
                                  dup = Dup,
                                  qos = QoS,
                                  retain = Retain}, S) ->
    S1 = if 
             S == undefined -> <<>>;
             true           -> [", ", S]
         end,
    io_lib:format("~s(Q~p, R~p, D~p~s)", [type_name(Type), QoS, i(Retain), i(Dup), S1]).

format_variable(undefined, _) ->
    undefined;
format_variable(Variable, undefined) ->
    format_variable(Variable);
format_variable(Variable, Payload) ->
    io_lib:format("~s, Payload=~p", [format_variable(Variable), Payload]).

format_variable(#mqtt_packet_connect{
                 proto_ver   = ProtoVer,
                 proto_name  = ProtoName,
                 will_retain = WillRetain,
                 will_qos    = WillQoS,
                 will_flag   = WillFlag,
                 clean_sess  = CleanSess,
                 keep_alive  = KeepAlive,
                 client_id   = ClientId,
                 will_topic  = WillTopic, 
                 will_msg    = WillMsg, 
                 username    = Username, 
                 password    = Password}) ->
    Format = "ClientId=~s, ProtoName=~s, ProtoVsn=~p, CleanSess=~s, KeepAlive=~p, Username=~s, Password=~s",
    Args = [ClientId, ProtoName, ProtoVer, CleanSess, KeepAlive, Username, format_password(Password)],
    {Format1, Args1} = if 
                        WillFlag -> { Format ++ ", Will(Q~p, R~p, Topic=~s, Msg=~s)",
                                      Args ++ [WillQoS, i(WillRetain), WillTopic, WillMsg] };
                        true -> {Format, Args}
                       end,
    io_lib:format(Format1, Args1);

format_variable(#mqtt_packet_connack{ack_flags   = AckFlags,
                                     reason_code = ReasonCode}) ->
    io_lib:format("AckFlags=~p, RetainCode=~p", [AckFlags, ReasonCode]);

format_variable(#mqtt_packet_publish{topic_name = TopicName,
                                     packet_id  = PacketId}) ->
    io_lib:format("Topic=~s, PacketId=~p", [TopicName, PacketId]);

format_variable(#mqtt_packet_puback{packet_id = PacketId}) ->
    io_lib:format("PacketId=~p", [PacketId]);

format_variable(#mqtt_packet_subscribe{packet_id     = PacketId,
                                       topic_filters = TopicFilters}) ->
    io_lib:format("PacketId=~p, TopicFilters=~p", [PacketId, TopicFilters]);

format_variable(#mqtt_packet_unsubscribe{packet_id = PacketId,
                                         topics    = Topics}) ->
    io_lib:format("PacketId=~p, Topics=~p", [PacketId, Topics]);

format_variable(#mqtt_packet_suback{packet_id = PacketId,
                                    reason_codes = ReasonCodes}) ->
    io_lib:format("PacketId=~p, ReasonCodes=~p", [PacketId, ReasonCodes]);

format_variable(#mqtt_packet_unsuback{packet_id = PacketId}) ->
    io_lib:format("PacketId=~p", [PacketId]);

format_variable(PacketId) when is_integer(PacketId) ->
    io_lib:format("PacketId=~p", [PacketId]);

format_variable(undefined) -> undefined.

format_password(undefined) -> undefined;
format_password(_Password) -> '******'.

i(true)  -> 1;
i(false) -> 0;
i(I) when is_integer(I) -> I.
