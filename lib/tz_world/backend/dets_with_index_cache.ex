defmodule TzWorld.Backend.DetsWithIndexCache do
  @behaviour TzWorld.Backend

  use GenServer

  alias Geo.Point

  @timeout 10_000
  @tz_world_version :tz_world_version

  @doc false
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  def init(_state) do
    {:ok, [], {:continue, :open_dets_file}}
  end

  def version do
    GenServer.call(__MODULE__, :version, @timeout)
  end

  @doc """
  Returns the timezone name for the given coordinates specified
  as either a `Geo.Point` or as `lng` and `lat` parameters

  ## Examples

      iex> TzWorld.timezone_at(%Geo.Point{coordinates: {3.2, 45.32}})
      {:ok, "Europe/Paris"}

      iex> TzWorld.timezone_at(3.2, 45.32)
      {:ok, "Europe/Paris"}


  The algorithm starts by filtering out timezones whose bounding
  box does not contain the given point.

  Once filtered, the first timezone which contains the given
  point is returned, or `nil` if none of the timezones match.

  """
  @spec timezone_at(Geo.Point.t()) :: {:ok, String.t()} | {:error, String.t()}
  def timezone_at(%Point{} = point) do
    GenServer.call(__MODULE__, {:timezone_at, point}, @timeout)
  end

  @doc """
  Reload the timezone geo JSON data.

  This allows for the data to be reloaded,
  typically with a new release, without
  restarting the application.

  """
  @spec reload_timezone_data :: :ok
  def reload_timezone_data do
    GenServer.call(__MODULE__, :reload_data, @timeout * 3)
  end

  @dets_file :code.priv_dir(:tz_world) ++ '/timezones-geodata.dets'
  @slots 800

  def filename do
    @dets_file
  end

  @dets_options [file: @dets_file, estimated_no_objects: @slots]
  def get_geodata_table do
    :dets.open_file(__MODULE__, @dets_options)
  end

  def save_dets_geodata do
    {:ok, t} = :dets.open_file(__MODULE__, @dets_options)
    :ok = :dets.delete_all_objects(t)

    {:ok, geodata} = TzWorld.GeoData.load_compressed_data()
    [version | shapes] = geodata

    for shape <- shapes do
      add_to_dets(t, shape)
    end

    :ok = :dets.insert(t, {@tz_world_version, version})
    :dets.close(t)
  end

  defp add_to_dets(t, shape) do
    case shape.properties.bounding_box do
      %Geo.Polygon{} = box ->
        [[{x_min, y_max}, {_, y_min}, {x_max, _}, _]] = box.coordinates
        :dets.insert(t, {{x_min, x_max, y_min, y_max}, shape})

      polygons when is_list(polygons) ->
        for box <- polygons do
          [[{x_min, y_max}, {_, y_min}, {x_max, _}, _]] = box.coordinates
          :dets.insert(t, {{x_min, x_max, y_min, y_max}, shape})
        end
    end
  end

  # --- Server callback implementation

  @doc false
  def handle_continue(:open_dets_file, _state) do
    {:ok, __MODULE__} = get_geodata_table()
    {:noreply, get_index_cache()}
  end

  @doc false
  def handle_call({:timezone_at, %Geo.Point{} = point}, _from, state) do
    {:reply, find_zone(point, state), state}
  end

  @doc false
  def handle_call(:version, _from, state) do
    [{_, version}] = :dets.lookup(__MODULE__, @tz_world_version)
    {:reply, version, state}
  end

  @doc false
  def handle_call(:reload_data, _from, _state) do
    :dets.close(__MODULE__)
    :ok = save_dets_geodata()
    {:ok, __MODULE__} = get_geodata_table()
    {:reply, get_geodata_table(), get_index_cache()}
  end

  @doc false
  defp find_zone(%Geo.Point{} = point, state) do
    point
    |> select_candidates(state)
    |> Enum.find(&TzWorld.contains?(&1, point))
    |> case do
      %Geo.MultiPolygon{properties: %{tzid: tzid}} -> {:ok, tzid}
      %Geo.Polygon{properties: %{tzid: tzid}} -> {:ok, tzid}
      nil -> {:error, :time_zone_not_found}
    end
  end

  defp select_candidates(%{coordinates: {lng, lat}}, state) do
    Enum.filter(state, fn {x_min, x_max, y_min, y_max} ->
      lng >= x_min && lng <= x_max && lat >= y_min && lat <= y_max
    end)
    |> Enum.map(fn bounding_box ->
      [{_key, value}] = :dets.lookup(__MODULE__, bounding_box)
      value
    end)
  end

  def get_index_cache do
    :dets.select(__MODULE__, index_spec())
  end

  def index_spec do
    [{{{:"$1", :"$2", :"$3", :"$4"}, :"$5"}, [], [{{:"$1", :"$2", :"$3", :"$4"}}]}]
  end
end