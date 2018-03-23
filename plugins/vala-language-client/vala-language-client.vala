/*-
 * Copyright (c) 2018 elementary LLC. (https://elementary.io)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * Authored by: David Hewitt <davidmhewitt@gmail.com>
 */

public class Scratch.Plugins.ValaLanguageClient : Peas.ExtensionBase,  Peas.Activatable {

    Scratch.Services.Interface plugins;
    Scratch.MainWindow window;
    public Object object { owned get; construct; }

    private Gee.HashMap<string, LanguageServer.Client> clients = new Gee.HashMap<string, LanguageServer.Client> ();
    private Gee.ArrayList<string> initializing_clients = new Gee.ArrayList<string> ();
    private Gee.HashMap<string, Scratch.Services.Document> latest_document = new Gee.HashMap<string, Scratch.Services.Document> ();
    private Gee.HashMap<string, int> versions = new Gee.HashMap<string, int> ();
    private Gee.HashMap<string, Gee.ArrayList<LanguageServer.Types.Diagnostic>> diagnostics = new Gee.HashMap<string, Gee.ArrayList<LanguageServer.Types.Diagnostic>> ();
    private Gee.HashMap<string, ulong> changed_signals = new Gee.HashMap<string, ulong> ();
    public void update_state () {}

    public void activate () {
        plugins = (Scratch.Services.Interface) object;
        plugins.hook_document.connect (on_hook_document);
        plugins.hook_window.connect ((w) => {
            this.window = w;
        });
    }

    public void deactivate () {
        plugins.hook_document.disconnect (on_hook_document);
        foreach (var client in clients.values) {
            client.exit ();
        }
    }

    void on_hook_document (Scratch.Services.Document doc) {
        if (doc.get_language_name () == "Vala") {
            update_diagnostics ();

            var uri = doc.file.get_uri ();
            if (!versions.has_key (uri)) {
                versions[uri] = 1;
            }

            var root_path = window.folder_manager_view.get_root_path_for_file (doc.file.get_path ());
            if (root_path != null) {
                doc.source_view.query_tooltip.connect (on_query_tooltip);
                var root_uri = File.new_for_path (root_path).get_uri ();
                if (!(root_uri in initializing_clients) && !clients.has_key (root_uri)) {
                    initializing_clients.add (root_uri);
                    unbind_changed (root_uri);
                    latest_document[root_uri] = doc;
                    bind_changed (root_uri);

                    var client = new LanguageServer.Client ("com.github.davidmhewitt.vls");
                    client.diagnostics_published.connect (on_diagnostics_published);

                    var initialize_params = new LanguageServer.Types.InitializeParams () {
                        rootUri = root_uri
                    };

                    client.initialize.begin (initialize_params, (o, res) => {
                        try {
                            var result = client.initialize.end (res);
                            clients[root_uri] = client;
                            fire_did_open (root_uri);
                        } catch (Error e) {
                            warning ("error initializing language server: %s", e.message);
                        }
                    });
                } else {
                    if (doc != latest_document[root_uri]) {
                        unbind_changed (root_uri);
                        latest_document[root_uri] = doc;
                        bind_changed (root_uri);

                        if (clients.has_key (root_uri)) {
                            fire_did_open (root_uri);
                        }
                    }
                }
            }
        }
    }

    private void fire_did_open (string root_uri) {
        var file_uri = latest_document[root_uri].file.get_uri ();
        var item = new LanguageServer.Types.TextDocumentItem () {
            uri = file_uri,
            languageId = "vala",
            number = versions[file_uri],
            text = latest_document[root_uri].source_view.buffer.text
        };

        clients[root_uri].did_open.begin (item);
    }

    private void bind_changed (string root_uri) {
        var doc = latest_document[root_uri];
        var uri = doc.file.get_uri ();

        changed_signals[root_uri] = doc.source_view.buffer.changed.connect (() => {
            if (clients.has_key (root_uri)) {
                versions[uri] = versions[uri] + 1;
                var change = new LanguageServer.Types.TextDocumentContentChangeEvent () {
                    rangeLength = doc.source_view.buffer.text.length,
                    text = doc.source_view.buffer.text
                };

                var params = new LanguageServer.Types.DidChangeTextDocumentParams () {
                    textDocument = new LanguageServer.Types.VersionedTextDocumentIdentifier () {
                        uri = uri,
                        version = versions[uri]
                    },
                    contentChanges = new Gee.ArrayList<LanguageServer.Types.TextDocumentContentChangeEvent> ()
                };

                params.contentChanges.add (change);
                clients[root_uri].did_change (params);
            }
        });
    }

    private void unbind_changed (string root_uri) {
        if (changed_signals.has_key (root_uri)) {
            latest_document [root_uri].source_view.buffer.disconnect (changed_signals [root_uri]);
        }
    }

    private void update_diagnostics () {
        var current_document = window.split_view.get_current_view ().current_document;
        if (current_document == null) {
            return;
        }

        var current_uri = current_document.file.get_uri ();
        if (current_document.source_view == null) {
            return;
        }

        var buffer = current_document.source_view.buffer;
        Gtk.TextIter start, end;
        buffer.get_start_iter (out start);
        buffer.get_end_iter (out end);
        buffer.remove_tag_by_name ("warning_bg", start, end);
        buffer.remove_tag_by_name ("error_bg", start, end);

        if (diagnostics[current_uri].size > 0) {
            foreach (var problem in diagnostics[current_uri]) {
                var problem_start = problem.range.start;
                var problem_end = problem.range.end;
                buffer.get_iter_at_line_offset (out start, problem_start.line, problem_start.character);
                buffer.get_iter_at_line_offset (out end, problem_end.line, problem_end.character);

                if (problem.severity == LanguageServer.Types.DiagnosticSeverity.Error) {
                    buffer.apply_tag_by_name ("error_bg", start, end);
                } else if (problem.severity == LanguageServer.Types.DiagnosticSeverity.Warning) {
                    buffer.apply_tag_by_name ("warning_bg", start, end);
                }
            }
        }
    }

    private void on_diagnostics_published (string uri, Gee.ArrayList<LanguageServer.Types.Diagnostic> diagnostics) {
        var current_document = window.split_view.get_current_view ().current_document;
        var current_uri = current_document.file.get_uri ();

        this.diagnostics[uri] = diagnostics;

        if (uri != current_uri) {
            return;
        }

        update_diagnostics ();
    }

    private bool on_query_tooltip (int x, int y, bool keyboard_tooltip, Gtk.Tooltip tooltip) {
        var current_document = window.split_view.get_current_view ().current_document;
        var current_uri = current_document.file.get_uri ();
        var source_view = current_document.source_view;

        if (!diagnostics.has_key (current_uri) || diagnostics[current_uri].size == 0) {
            return false;
        }

        int buffer_x, buffer_y;
        Gtk.TextIter hover_iter;
        source_view.window_to_buffer_coords (Gtk.TextWindowType.WIDGET, x, y, out buffer_x, out buffer_y);
        source_view.get_iter_at_location (out hover_iter, buffer_x, buffer_y);

        foreach (var diagnostic in diagnostics[current_uri]) {
            if (hover_iter.get_line () < diagnostic.range.start.line) {
                continue;
            }

            if (hover_iter.get_line () > diagnostic.range.end.line) {
                continue;
            }

            if (hover_iter.get_line_offset () < diagnostic.range.start.character) {
                continue;
            }

            if (hover_iter.get_line_offset () > diagnostic.range.end.character) {
                continue;
            }

            tooltip.set_text (diagnostic.message);
            return true;
        }

        return false;
    }
}

[ModuleInit]
public void peas_register_types (GLib.TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type (typeof (Peas.Activatable),
                                       typeof (Scratch.Plugins.ValaLanguageClient));
}
