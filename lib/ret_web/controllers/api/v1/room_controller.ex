defmodule RetWeb.Api.V1.RoomController do
  use RetWeb, :controller
  import RetWeb.ApiHelpers

  alias Ret.{Account, AccountFavorite, Hub, Scene, SceneListing, Repo}

  import Canada, only: [can?: 2]
  import Ecto.Query, only: [where: 3, preload: 2, join: 5]

  # Limit to 1 TPS
  plug(RetWeb.Plugs.RateLimit)

  # Only allow access to remove hubs with secret header
  plug(RetWeb.Plugs.HeaderAuthorization when action in [:delete])

  @show_request_schema %{
                         "type" => "object",
                         "properties" => %{
                           "room_ids" => %{
                             "type" => "array",
                             "items" => %{
                               "type" => "string"
                             },
                             "only_favorites" => %{
                               "type" => "bool"
                             }
                           }
                         }
                       }
                       |> ExJsonSchema.Schema.resolve()

  def index(conn, params) do
    exec_api_show(conn, params, @show_request_schema, &render_hub_records/2)
  end

  defp filter_by_created_by_account(query, %Account{} = account) do
    query
    |> preload(:created_by_account)
    |> where([hub], hub.created_by_account_id == ^account.account_id)
  end

  defp filter_by_created_by_account(query, _params) do
    query
    |> ensure_query_returns_no_results
  end

  defp maybe_filter_by_room_ids(query, %{"room_ids" => room_ids}) do
    query |> maybe_filter_by_room_ids(room_ids)
  end

  defp maybe_filter_by_room_ids(query, room_ids) when is_list(room_ids) do
    query |> where([hub], hub.hub_sid in ^room_ids)
  end

  defp maybe_filter_by_room_ids(query, _params) do
    query
  end

  defp maybe_filter_by_only_favorites(query, account, %{"only_favorites" => "true"}) do
    query |> filter_by_favorite(account)
  end

  defp maybe_filter_by_only_favorites(query, account, %{"only_favorites" => true}) do
    query |> filter_by_favorite(account)
  end

  defp maybe_filter_by_only_favorites(query, _, _) do
    query
  end

  defp filter_by_entry_mode(query, mode) do
    query
    |> where([_], ^[entry_mode: mode])
  end

  defp filter_by_allow_promotion(query, allow) do
    query
    |> where([_], ^[allow_promotion: allow])
  end

  defp filter_by_favorite(query, %Account{} = account) do
    query
    |> join(:inner, [h], f in AccountFavorite, on: f.hub_id == h.hub_id and f.account_id == ^account.account_id)
  end

  defp filter_by_favorite(query, _) do
    query
    |> ensure_query_returns_no_results
  end

  defp ensure_query_returns_no_results(query) do
    query
    |> where([_], false)
  end

  defp hub_query(account, params) do
    Ret.Hub
    |> filter_by_entry_mode("allow")
    |> maybe_filter_by_room_ids(params)
    |> maybe_filter_by_only_favorites(account, params)
  end

  defp render_hub_records(conn, params) do
    account = Guardian.Plug.current_resource(conn)

    favorited_rooms =
      hub_query(account, params)
      |> filter_by_favorite(account)
      |> Ret.Repo.all()

    created_by_account_rooms =
      hub_query(account, params)
      |> filter_by_created_by_account(account)
      |> Ret.Repo.all()

    public_rooms =
      hub_query(account, params)
      |> filter_by_allow_promotion(true)
      |> Ret.Repo.all()

    rooms = (favorited_rooms ++ created_by_account_rooms ++ public_rooms) |> Enum.uniq_by(fn room -> room.hub_sid end)

    results =
      rooms
      |> Enum.map(fn hub ->
        Phoenix.View.render(RetWeb.Api.V1.RoomView, "show.json", %{hub: hub})
      end)

    {:ok, results}
  end

  def create(conn, %{"hub" => %{"scene_id" => scene_id}} = params) do
    scene = Scene.scene_or_scene_listing_by_sid(scene_id)

    %Hub{}
    |> Hub.changeset(scene, params["hub"])
    |> exec_create(conn)
  end

  def create(conn, %{"hub" => _hub_params} = params) do
    scene_listing = SceneListing.get_random_default_scene_listing()

    %Hub{}
    |> Hub.changeset(scene_listing, params["hub"])
    |> exec_create(conn)
  end

  defp exec_create(hub_changeset, conn) do
    account = Guardian.Plug.current_resource(conn)

    if account |> can?(create_hub(nil)) do
      {result, hub} =
        hub_changeset
        |> Hub.add_account_to_changeset(account)
        |> Repo.insert()

      case result do
        :ok -> render(conn, "create.json", hub: hub)
        :error -> conn |> send_resp(422, "invalid hub")
      end
    else
      conn |> send_resp(401, "unauthorized")
    end
  end

  def update(conn, %{"id" => hub_sid, "hub" => hub_params}) do
    account = Guardian.Plug.current_resource(conn)

    case Hub
         |> Repo.get_by(hub_sid: hub_sid)
         |> Repo.preload([:created_by_account, :hub_bindings, :hub_role_memberships]) do
      %Hub{} = hub ->
        if account |> can?(update_hub(hub)) do
          update_with_hub(conn, account, hub, hub_params)
        else
          conn |> send_resp(401, "You cannot update this hub")
        end

      _ ->
        conn |> send_resp(404, "not found")
    end
  end

  defp update_with_hub(conn, account, hub, hub_params) do
    if is_nil(hub_params["scene_id"]) do
      update_with_hub_and_scene(conn, account, hub, nil, hub_params)
    else
      case Scene.scene_or_scene_listing_by_sid(hub_params["scene_id"]) do
        nil -> conn |> send_resp(422, "scene not found")
        scene -> update_with_hub_and_scene(conn, account, hub, scene, hub_params)
      end
    end
  end

  defp update_with_hub_and_scene(conn, account, hub, scene, hub_params) do
    changeset =
      hub
      |> Hub.add_attrs_to_changeset(hub_params)
      |> maybe_add_new_scene(scene)
      |> maybe_add_member_permissions(hub, hub_params)
      |> maybe_add_promotion(account, hub, hub_params)

    hub = changeset |> Repo.update!() |> Repo.preload(Hub.hub_preloads())

    conn |> render("show.json", %{hub: hub, embeddable: account |> can?(embed_hub(hub))})
  end

  defp maybe_add_new_scene(changeset, nil), do: changeset

  defp maybe_add_new_scene(changeset, scene), do: changeset |> Hub.add_new_scene_to_changeset(scene)

  defp maybe_add_member_permissions(changeset, hub, %{"member_permissions" => %{}} = hub_params),
    do: changeset |> Hub.add_member_permissions_update_to_changeset(hub, hub_params)

  defp maybe_add_member_permissions(changeset, _hub, _), do: changeset

  defp maybe_add_promotion(changeset, account, hub, %{"allow_promotion" => _} = hub_params),
    do: changeset |> Hub.maybe_add_promotion_to_changeset(account, hub, hub_params)

  defp maybe_add_promotion(changeset, _account, _hub, _), do: changeset

  def delete(conn, %{"id" => hub_sid}) do
    Hub
    |> Repo.get_by(hub_sid: hub_sid)
    |> Hub.changeset_for_entry_mode(:deny)
    |> Repo.update!()

    conn |> send_resp(200, "OK")
  end
end
