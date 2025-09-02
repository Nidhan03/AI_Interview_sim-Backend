from tree_sitter import Language, Parser
import tree_sitter_python




def build_python_context_graph(code: str):

    PY_LANGUAGE = Language(tree_sitter_python.language())
    parser = Parser()
    parser.language = PY_LANGUAGE
    """
    Parse Python `code` with tree-sitter and return a simple code context graph.

    Returns:
        {
          "nodes": [{"id": int, "type": "class|function|method|file",
                     "name": str,
                     "range": ((start_row, start_col), (end_row, end_col))}],
          "edges": [{"src": int, "dst": int, "type": "contains|calls"}]
        }
    """
    tree = parser.parse(code.encode("utf8"))
    root = tree.root_node

    nodes, edges = [], []
    next_id = 0
    symbols = {}

    def new_node(kind, name, node):
        nonlocal next_id
        nid = next_id
        next_id += 1
        nodes.append({
            "id": nid,
            "type": kind,
            "name": name or "",
            "range": (node.start_point, node.end_point),
        })
        symbols[(kind, name)] = nid
        return nid

    def get_name(node):
        name_field = node.child_by_field_name("name")
        if name_field:
            return code[name_field.start_byte:name_field.end_byte]
        for ch in node.children:
            if ch.type == "identifier":
                return code[ch.start_byte:ch.end_byte]
        return ""

    def callee_name(call_node):
        fn = call_node.child_by_field_name("function")
        if not fn:
            return ""
        if fn.type == "identifier":
            return code[fn.start_byte:fn.end_byte]
        if fn.type == "attribute":
            attr = fn.child_by_field_name("attribute")
            if attr:
                return code[attr.start_byte:attr.end_byte]
            return code[fn.start_byte:fn.end_byte].split(".")[-1]
        return code[fn.start_byte:fn.end_byte].split("(")[0].split(".")[-1]

    scope_stack = []
    file_id = new_node("file", "", root)
    scope_stack.append((file_id, "file", ""))

    def current_class():
        for _, kind, qn in reversed(scope_stack):
            if kind == "class":
                return qn
        return None

    def walk(node, parent_id):
        kind = None
        if node.type == "class_definition":
            kind = "class"
        elif node.type == "function_definition":
            kind = "function"
            if current_class():
                kind = "method"

        current_id = parent_id
        if kind:
            nm = get_name(node)
            cls = current_class()
            qn = f"{cls}.{nm}" if (kind == "method" and cls) else nm
            current_id = symbols.get((kind, qn))
            if current_id is None:
                current_id = new_node(kind, qn, node)
            edges.append({"src": parent_id, "dst": current_id, "type": "contains"})
            scope_stack.append((current_id, kind, qn))

        if node.type == "call":
            callee = callee_name(node)
            if callee and scope_stack:
                src_id = scope_stack[-1][0]
                callee_id = symbols.get(("function", callee)) or \
                            symbols.get(("method", callee))
                if callee_id is None:
                    callee_id = new_node("function", callee, node)
                edges.append({"src": src_id, "dst": callee_id, "type": "calls"})

        for ch in node.children:
            if ch.is_named:
                walk(ch, current_id)

        if kind:
            scope_stack.pop()

    walk(root, file_id)
    return {"nodes": nodes, "edges": edges}


