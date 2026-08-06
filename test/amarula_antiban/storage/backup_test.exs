defmodule AmarulaAntiban.Storage.BackupTest do
  use ExUnit.Case, async: true

  alias AmarulaAntiban.Storage.Backup

  setup do
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "backup_inner_#{unique}")
    backup_dir = Path.join(System.tmp_dir!(), "backup_dir_#{unique}")

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(backup_dir)
    end)

    opts = [adapter: {Amarula.Storage.File, root: root}, backup_dir: backup_dir, retention: 2]
    %{opts: opts, backup_dir: backup_dir}
  end

  test "reads and writes pass through to the inner adapter", %{opts: opts} do
    state = Backup.new(opts)
    assert :error = Backup.get(state, :p1, :creds, :self)
    assert :ok = Backup.put(state, :p1, :creds, :self, %{secret: 1})
    assert {:ok, %{secret: 1}} = Backup.get(state, :p1, :creds, :self)
  end

  test "non-:creds namespaces are never backed up", %{opts: opts, backup_dir: backup_dir} do
    state = Backup.new(opts)
    assert :ok = Backup.put(state, :p1, :session, "addr", %{a: 1})
    assert :ok = Backup.put(state, :p1, :session, "addr", %{a: 2})
    refute File.dir?(backup_dir)
  end

  test "backs up the previous :creds value before every overwrite", %{
    opts: opts,
    backup_dir: backup_dir
  } do
    state = Backup.new(opts)
    assert :ok = Backup.put(state, :p1, :creds, :self, %{gen: 1})
    assert Backup.list_backups(opts, :p1, :self) == []

    assert :ok = Backup.put(state, :p1, :creds, :self, %{gen: 2})
    assert [backup_id] = Backup.list_backups(opts, :p1, :self)
    assert {:ok, %{gen: 1}} = Backup.read_backup(opts, backup_id)

    assert :ok = Backup.put(state, :p1, :creds, :self, %{gen: 3})
    assert [newest, older] = Backup.list_backups(opts, :p1, :self)
    assert {:ok, %{gen: 2}} = Backup.read_backup(opts, newest)
    assert {:ok, %{gen: 1}} = Backup.read_backup(opts, older)

    assert {:ok, %{gen: 3}} = Backup.get(state, :p1, :creds, :self)
    assert File.dir?(backup_dir)
  end

  test "prunes backups beyond retention", %{opts: opts} do
    state = Backup.new(opts)

    Enum.each(1..5, fn generation ->
      assert :ok = Backup.put(state, :p1, :creds, :self, %{gen: generation})
    end)

    backups = Backup.list_backups(opts, :p1, :self)
    assert length(backups) == 2
    assert {:ok, %{gen: 4}} = Backup.read_backup(opts, Enum.at(backups, 0))
    assert {:ok, %{gen: 3}} = Backup.read_backup(opts, Enum.at(backups, 1))
  end

  test "backups are isolated per profile and per key", %{opts: opts} do
    state = Backup.new(opts)
    assert :ok = Backup.put(state, :p1, :creds, :self, %{owner: :p1, gen: 1})
    assert :ok = Backup.put(state, :p2, :creds, :self, %{owner: :p2, gen: 1})
    assert :ok = Backup.put(state, :p1, :creds, :self, %{owner: :p1, gen: 2})
    assert :ok = Backup.put(state, :p2, :creds, :self, %{owner: :p2, gen: 2})

    assert [p1_backup] = Backup.list_backups(opts, :p1, :self)
    assert {:ok, %{owner: :p1, gen: 1}} = Backup.read_backup(opts, p1_backup)

    assert [p2_backup] = Backup.list_backups(opts, :p2, :self)
    assert {:ok, %{owner: :p2, gen: 1}} = Backup.read_backup(opts, p2_backup)
  end

  test "delete removes from the inner adapter without touching backups", %{opts: opts} do
    state = Backup.new(opts)
    assert :ok = Backup.put(state, :p1, :creds, :self, %{gen: 1})
    assert :ok = Backup.put(state, :p1, :creds, :self, %{gen: 2})
    assert :ok = Backup.delete(state, :p1, :creds, :self)
    assert :error = Backup.get(state, :p1, :creds, :self)
    assert [_backup] = Backup.list_backups(opts, :p1, :self)
  end

  test "clear/list_profiles/list_keys delegate to the inner adapter when it supports them", %{
    opts: opts
  } do
    state = Backup.new(opts)
    assert :ok = Backup.put(state, :p1, :creds, :self, %{gen: 1})
    assert {:ok, profiles} = Backup.list_profiles(state)
    assert "p1" in profiles

    assert :ok = Backup.put(state, :p1, :session, "addr", %{a: 1})
    assert {:ok, keys} = Backup.list_keys(state, :p1, :session)
    assert "addr" in keys

    assert :ok = Backup.clear(state, :p1)
    assert :error = Backup.get(state, :p1, :creds, :self)
  end

  test "list_backups returns an empty list when no backup directory exists yet", %{opts: opts} do
    assert Backup.list_backups(opts, :never_written, :self) == []
  end
end
