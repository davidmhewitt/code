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
            versions[doc.file.get_uri ()] = 1;
            var root_path = window.folder_manager_view.get_root_path_for_file (doc.file.get_path ());
            if (root_path != null) {
                var root_uri = File.new_for_path (root_path).get_uri ();
                if (!(root_uri in initializing_clients) && !clients.has_key (root_uri)) {
                    initializing_clients.add (root_uri);
                    latest_document[root_uri] = doc;

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
                        latest_document[root_uri] = doc;
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

    private void on_diagnostics_published (string uri, Gee.ArrayList<LanguageServer.Types.Diagnostic> diagnostics) {
        var current_document = window.split_view.get_current_view ().current_document;
        var current_uri = current_document.file.get_uri ();
        if (uri == current_uri && diagnostics.size > 0) {
            var buffer = current_document.source_view.buffer;
            Gtk.TextIter start, end;
            buffer.get_start_iter (out start);
            buffer.get_end_iter (out end);
            buffer.remove_tag_by_name ("warning_bg", start, end);
            buffer.remove_tag_by_name ("error_bg", start, end);

            foreach (var problem in diagnostics) {
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
}

[ModuleInit]
public void peas_register_types (GLib.TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type (typeof (Peas.Activatable),
                                       typeof (Scratch.Plugins.ValaLanguageClient));
}
