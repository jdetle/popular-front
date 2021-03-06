import Html exposing (..)
import Html.Attributes as Attr exposing (..)
import Html.Events exposing (..)
import RemoteData exposing (RemoteData(..))
import WebSocket
import Http
import Task
import Time exposing (Time, now)
import Json.Decode  exposing (decodeString)

import JMessages exposing (..)
import JSessions exposing (..)

main =
  Html.program
    { init = init
    , view = view
    , update = update
    , subscriptions = subscriptions
    }

type RawOrRendered = Raw | Rendered

-- MODEL

type alias Model =
  { input : String
  , messages : List String
  , msgs : List Jmsg
  , index : Maybe Int
  , connectionString : String
  , raw : RawOrRendered
  , focused : Maybe Int
  , server : String
  , sessions : RemoteData Http.Error (List Session)
  , activeSession : Maybe Session
  }


init : (Model, Cmd Msg)
init = (
  { input = ""
  , messages = []
  , msgs = []
  , index = Nothing
  , connectionString = ""
  , raw = Rendered
  , focused = Nothing
  , server = "localhost:8888"
  , sessions = NotAsked
  --, sessions = Success sampleSessions
  , activeSession = Nothing
  }
  --, Cmd.none)
  , Task.perform identity (Task.succeed ConnectAPI))



-- UPDATE

type Msg
  = Input String
  | Send
  | ConnectKernel
  | ConnectAPI
  | Ping String
  | NewMessage String
  | NewTimeMessage Time String
  | UpdateIndex String
  | GetTimeAndThen (Time -> Msg)
  | ToggleRendered
  | Focus Int
  | ChangeServer String
  | NewSessions (Result Http.Error (List Session))
  | SetActiveSession Session
  | ClearAllMessages


newMessage str = GetTimeAndThen (\time -> NewTimeMessage time str)


ws_url : Model -> String
--ws_url = "ws://localhost:8888/api/kernels/d341ae22-0258-482b-831a-fa0a0370ffba"
ws_url model
  =
  case model.activeSession of
  Nothing ->  Debug.log "~~~ uhoh" "http://shouldnothappen"
  Just s ->
    Debug.log "sending ws to..."
     "ws://" ++ model.server ++ "/api/kernels/" ++ s.kernel.id ++ "/channels"

kernel_info_request_msg = """{"header":{"msg_type":  "kernel_info_request", "msg_id":""}, "parent_header": {}, "metadata":{}}"""
empty_execute_request_msg = """{"header":{"msg_type":  "execute_request", "msg_id":""}, "parent_header": {}, "metadata":{}}"""
error_execute_request_msg = """{"header":{"msg_type":  "execute_request", "msg_id":"hi"}, "parent_header": {}, "content":
{"code": "import IPython.displas as d; d.HTML('<b>fancy</b>'"
,"silent": false , "store_history": true , "user_expressions" : {} , "allow_stdin": true , "stop_on_error": true }, "metadata":{}}"""
fancy_execute_request_msg = """{"header":{"msg_type":  "execute_request", "msg_id":"hi"}, "parent_header": {}, "content":
{"code": "import IPython.displas as d; d.HTML('<b>fancy</b>')"
,"silent": false , "store_history": true , "user_expressions" : {} , "allow_stdin": true , "stop_on_error": true }, "metadata":{}}"""
stdout_execute_request_msg = """{"header":{"msg_type":  "execute_request", "msg_id":"hi"}, "parent_header": {}, "content":
{"code": "print('hallo JupyterCon!')"
,"silent": false , "store_history": true , "user_expressions" : {} , "allow_stdin": true , "stop_on_error": true }, "metadata":{}}"""

update : Msg -> Model -> (Model, Cmd Msg)
update msg model =
  case msg of
    Input newInput ->
      { model
      | input = newInput
      } ! [ Cmd.none ]

    ConnectKernel ->
      { model
      | input = ""
      } ! [ WebSocket.send (ws_url model) kernel_info_request_msg ]

    Ping raw_msg ->
    let
      new_msgs = case decodeString decodeJmsg raw_msg of
        Ok m -> [m]
        Err x -> []
    in
       { model
       | messages = List.append model.messages  [raw_msg]
       , msgs = List.append model.msgs new_msgs
       } ! [ WebSocket.send (ws_url model) raw_msg ]

    Send ->
      { model
      | input = ""
      , sessions = Loading
      } ! [ WebSocket.send (ws_url model) model.input ]

    NewMessage str ->
    let
      latest = case decodeString decodeJmsg str of
        Ok jmsg -> [(Debug.log "IT WORKS" jmsg)]
        Err msg -> let error = (Debug.log "Nope" msg)
                  in []
    in
      { model
      --| messages = str :: model.messages
      | messages = model.messages ++ [str]
      , msgs = model.msgs ++ latest
      --, last_status = status
      } ! [ Cmd.none ]

    GetTimeAndThen successHandler ->
    ( model, (Task.perform successHandler now) )

    NewTimeMessage time str ->
    { model
    --| messages = str :: model.messages
    | messages = model.messages ++ [str ++ (formatTime time)]
    } ! [ Cmd.none ]
    UpdateIndex str ->
    { model
    | index = Just <| Result.withDefault 0 <| String.toInt str
    } ! [ Cmd.none ]
    ToggleRendered ->
    { model
    | raw  = case model.raw of
        Raw -> Rendered
        Rendered -> Raw
    } ! [ Cmd.none ]
    Focus i ->
    { model
    | focused = case Just i == model.focused  of
        True -> Nothing
        False -> Just i
    } ! [ Cmd.none ]

    ChangeServer s ->
    let
      new_model =
      { model
      | server = s
      , sessions = Loading
      }
    in
      new_model  ! [getSession new_model]

    ConnectAPI ->
      update (ChangeServer model.server) model


    NewSessions result ->
    let
      new_sessions = case result of
        Ok sessions -> Debug.log "hallo" Success sessions
        Err x ->  Debug.log "failure" Failure x
    in
      { model
      | sessions = new_sessions
      , activeSession = List.head <| Result.withDefault [] result
      } ! [Cmd.none]

    SetActiveSession s ->
    { model | activeSession = Just s} ! [Cmd.none]

    ClearAllMessages ->
    { model |  msgs = [], messages= [], focused=Nothing} ! [Cmd.none]

-- Timezone offset (relative to UTC)
tz = -7

formatTime : Time -> String
formatTime t
  = String.concat <| List.intersperse ":" <| List.map toString
      [ floor (Time.inHours t)  % 24 + tz
      , floor (Time.inMinutes t)  % 60
      , floor (Time.inSeconds t)  % 60
      ]

api_url : Model -> String
api_url model =
-- TODO: this is brittle - we should check if there's already a leading http://
-- in the url and not add it to the front in that case
-- TODO: support tokens and password
  Debug.log "URL is: " "http://" ++ model.server ++ "/api/sessions"

getSession : Model -> Cmd Msg
getSession model =
  let
    request = Debug.log "calling url" Http.get (api_url model) decodeSessions
  in
    Http.send NewSessions request

-- SUBSCRIPTIONS

subscriptions : Model -> Sub Msg
subscriptions model =
  case model.activeSession of
    Nothing -> Sub.none
    _ -> WebSocket.listen (ws_url model) NewMessage


-- VIEW
(=>) = (,)

view : Model -> Html Msg
view model =
  div
    [ style
      [ "display" => "flex"
      , "margin" => "0"
      , "flex-direction" => "column"
      , "min-height" =>  "100vh"
      ]
    ]
    [ viewStatus model
    , div[] [toggleRenderedStatus model, kernelInfoButton, quickHTMLButton,
    quickHTMLButton2, quickHTMLButton3]
    , div [style ["display" => "flex", "flex-direction" => "row"]]
          [ div [] (viewValidMessages model)
          , viewFocused model]
    , input [onInput Input] []
    , button [onClick Send] [text "Send"]
    , button [onClick <| newMessage  "--- mark --- "] [text "add marker"]
    , button [onClick ClearAllMessages] [text "Clear all messages"]
        --<| "--- mark --- " ++ (toString <| Task.perform <| \a ->  Time.now )] [text "Add Marker"]
    , div [style ["flex" => "1"]] []
    , viewTimeSlider model
    , viewTimeSlider model
    , viewTimeSlider model
    ]

viewStatus : Model -> Html Msg
viewStatus model =
  let
    (color, message) = case model.sessions of
        NotAsked -> ("red", "Not connected")
        Loading -> ("yellow", "Loading...")
        Success _ -> ("green", "Connected")
        Failure x -> ("red", "Failed to connect")
  in
    div [style ["background-color" => color]] [viewServer model, text message]



viewMessage : Model -> Int -> Jmsg -> Html Msg
viewMessage model i msg =
  let
    s = case model.focused of
      Just j -> if i == j then ["background-color" => "orange"] else []
      Nothing -> []
    subj = getSubject msg
    content  = case model.focused of
      Just j -> if i == j then [ strong [] [text <| subj ]] else [text <| subj]
      Nothing -> [text <| subj]
  in
    div [style s, onClick (Focus i)] content

viewRawMessage : Int -> String -> Html Msg
viewRawMessage i msg =
  div [onClick (Focus i)] [ text msg , hr [] [] ]


viewValidMessages : Model -> List (Html Msg)
viewValidMessages model =
   case model.raw of
      Raw ->
        let msgs = case model.index of
          Nothing -> model.messages
          Just i -> List.take i model.messages
        in
          List.indexedMap viewRawMessage msgs

      Rendered ->
        let msgs =  case model.index of
          Nothing -> model.msgs
          Just i -> List.take i model.msgs
        in
          List.indexedMap (viewMessage model) msgs



viewTimeSlider : Model -> Html Msg
viewTimeSlider model =
  let
    len = case model.raw of
      Raw -> List.length model.messages
      Rendered -> List.length model.msgs
  in
  footer []
  [ input
      [ type_ "range"
      , Attr.min "0"
      , Attr.max <| toString len
      , value <| toString <| Maybe.withDefault len model.index
      , onInput UpdateIndex
      , style ["width" => "96%"]
      ] [text "hallo"]
  ]

toggleRenderedStatus : Model -> Html Msg
toggleRenderedStatus model =
  let nextToggleValue = case model.raw of
    Raw -> "Rendered"
    Rendered -> "Raw"
  in
    button [onClick ToggleRendered] [text nextToggleValue]

kernelInfoButton : Html Msg
kernelInfoButton =
    button [onClick ConnectKernel] [text "kernel info"]

quickHTMLButton =
    button [onClick <| Ping error_execute_request_msg] [text "get an error"]

quickHTMLButton2 =
    button [onClick <| Ping fancy_execute_request_msg] [text "get a fancy result"]

quickHTMLButton3 =
    button [onClick <| Ping stdout_execute_request_msg] [text "get some stdout"]

zip = List.map2 (,)

viewFocused : Model -> Html Msg
viewFocused model =
  case model.focused of
    Just i ->
    let
      msg_pair = List.head <| List.drop i (zip model.msgs model.messages)
      --msg_pair = List.head <| List.drop i model.msgs
      -- = List.head <| List.drop i
    in
    case msg_pair of
      Nothing -> div [] []
      -- Just msg
      Just (msg, raw) ->
        -- TODO: put flexbox styling here
        div [style ["flex" => "1"]] (renderMsg model msg )
       -- , text raw ]
    Nothing -> div [] []

getSubject : Jmsg -> String
getSubject msg =
  let
    state = ": " ++ Maybe.withDefault "" msg.content.execution_state
  in
    "(" ++ msg.channel ++ ") " ++ msg.msg_type ++ state

renderMsg : Model -> Jmsg -> List (Html Msg)
renderMsg model msg =
  [ table []
    [ tr []
      [ td [] [text "Subject:"]
      , td [] [text (getSubject msg)]
      ]
    , tr []
      [ td [] [text "From:"]
      , td [] [text "Kernel"]
      ]
    ]
  , text <| "***" ++  msg.msg_type ++ ": " ++ (Maybe.withDefault "" msg.content.execution_state)
       , text <| toString msg
  ]

viewServer model = span []
  [ input [onInput ChangeServer, value model.server] []
  , select [] <| sessionsToOptions model
  ]

sessionToOption : Session -> Html Msg
sessionToOption s = option [onClick (SetActiveSession s)] [text s.notebook.path]

sessionsToOptions : Model -> List (Html Msg)
sessionsToOptions model =
  case model.sessions of
    Success sessions -> List.map sessionToOption sessions
    --_ -> [option [disabled True, selected True] [text ""]]
    _ -> []


