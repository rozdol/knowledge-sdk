# frozen_string_literal: true

require "set"

module KnowledgeIntelligence
  class Projection
    attr_reader :nodes, :adjacency, :edge_records

    def initialize(nodes:, edges:)
      @nodes = Array(nodes).map(&:to_s).uniq.sort.freeze
      mutable = @nodes.each_with_object({}) { |node, result| result[node] = {} }
      @edge_records = {}
      Array(edges).sort_by { |edge| [edge.fetch(:source), edge.fetch(:target), edge.fetch(:id)] }.each do |edge|
        source = edge.fetch(:source).to_s
        target = edge.fetch(:target).to_s
        next if source == target || !mutable.key?(source) || !mutable.key?(target)

        mutable[source][target] ||= []
        mutable[target][source] ||= []
        mutable[source][target] << edge.fetch(:id).to_s
        mutable[target][source] << edge.fetch(:id).to_s
        @edge_records[edge.fetch(:id).to_s] = Immutable.copy(edge)
      end
      @adjacency = mutable.each_with_object({}) do |(node, neighbors), result|
        result[node] = neighbors.keys.sort.each_with_object({}) do |neighbor, item|
          item[neighbor] = neighbors[neighbor].uniq.sort.freeze
        end.freeze
      end.freeze
      @edge_records.freeze
      freeze
    end

    def neighbors(node)
      adjacency.fetch(node.to_s, {}).keys
    end

    def edge_ids(first, second)
      adjacency.fetch(first.to_s, {}).fetch(second.to_s, [])
    end

    def edge_count
      adjacency.values.sum { |neighbors| neighbors.length } / 2
    end

    def self.social(snapshot, as_of: Date.today)
      people = snapshot.records(type: "person").map(&:id)
      person_set = people.to_h { |id| [id, true] }
      edges = []
      snapshot.relationships(as_of: as_of).each do |record|
        source = record["subject_id"]
        target = record["object_id"]
        next unless person_set[source] && person_set[target]

        edges << { id: record.id, source: source, target: target, kind: record["predicate"], record_id: record.id }
      end
      snapshot.interactions(as_of: as_of, substantive_only: true).each do |record|
        participants = snapshot.reference_ids(record, "participants").select { |id| person_set[id] }
        participants.combination(2) do |first, second|
          edges << { id: "#{record.id}:#{first}:#{second}", source: first, target: second,
                     kind: "interaction", record_id: record.id }
        end
      end
      snapshot.records(type: "introduction").each do |record|
        next unless record["assertion_status"] == "asserted"

        ids = [record["introducer_id"], record["person_a_id"], record["person_b_id"]].compact
        ids.combination(2) do |first, second|
          edges << { id: "#{record.id}:#{first}:#{second}", source: first, target: second,
                     kind: "introduction", record_id: record.id }
        end
      end
      new(nodes: people, edges: edges)
    end

    def self.knowledge(snapshot, as_of: Date.today)
      records = snapshot.records.reject { |record| %w[relationship interaction introduction].include?(record.type) }
      nodes = records.map(&:id)
      node_set = nodes.to_h { |id| [id, true] }
      edges = snapshot.relationships(as_of: as_of).map do |record|
        next unless node_set[record["subject_id"]] && node_set[record["object_id"]]

        { id: record.id, source: record["subject_id"], target: record["object_id"],
          kind: record["predicate"], record_id: record.id }
      end.compact
      new(nodes: nodes, edges: edges)
    end
  end

  module GraphAlgorithms
    module_function

    def bfs(graph, start)
      return [] unless graph.adjacency.key?(start.to_s)

      queue = [start.to_s]
      cursor = 0
      visited = { start.to_s => true }
      order = []
      while cursor < queue.length
        node = queue[cursor]
        cursor += 1
        order << node
        graph.neighbors(node).each do |neighbor|
          next if visited[neighbor]

          visited[neighbor] = true
          queue << neighbor
        end
      end
      order.freeze
    end

    def dfs(graph, start)
      return [] unless graph.adjacency.key?(start.to_s)

      stack = [start.to_s]
      visited = {}
      order = []
      until stack.empty?
        node = stack.pop
        next if visited[node]

        visited[node] = true
        order << node
        graph.neighbors(node).reverse_each { |neighbor| stack << neighbor unless visited[neighbor] }
      end
      order.freeze
    end

    def shortest_path(graph, source, target)
      source = source.to_s
      target = target.to_s
      return [source].freeze if source == target && graph.adjacency.key?(source)
      return nil unless graph.adjacency.key?(source) && graph.adjacency.key?(target)

      tree = shortest_path_tree(graph, source, targets: [target])
      path_from_tree(tree, target)
    end

    def shortest_path_tree(graph, source, targets: nil, max_distance: nil)
      source = source.to_s
      return { source: source, parent: {}.freeze, distance: {}.freeze }.freeze unless graph.adjacency.key?(source)

      wanted = targets && Array(targets).map(&:to_s).to_h { |target| [target, true] }
      remaining = wanted&.length
      queue = [source]
      cursor = 0
      parent = { source => nil }
      distance = { source => 0 }
      while cursor < queue.length
        node = queue[cursor]
        cursor += 1
        break if max_distance && distance[node] >= max_distance

        graph.neighbors(node).each do |neighbor|
          next if parent.key?(neighbor)

          parent[neighbor] = node
          distance[neighbor] = distance[node] + 1
          queue << neighbor
          if wanted && wanted[neighbor]
            remaining -= 1
            return { source: source, parent: parent.freeze, distance: distance.freeze }.freeze if remaining.zero?
          end
        end
      end
      { source: source, parent: parent.freeze, distance: distance.freeze }.freeze
    end

    def path_from_tree(tree, target)
      target = target.to_s
      return nil unless tree.fetch(:distance).key?(target)

      path = [target]
      parent = tree.fetch(:parent)
      path.unshift(parent[path.first]) while parent[path.first]
      path.freeze
    end

    def connected_components(graph)
      visited = {}
      graph.nodes.each_with_object([]) do |node, result|
        next if visited[node]

        component = bfs(graph, node)
        component.each { |member| visited[member] = true }
        result << component.sort.freeze
      end.sort_by { |component| [component.first.to_s, component.length] }.freeze
    end

    def bridges(graph)
      time = 0
      discovered = {}
      low = {}
      parent = {}
      result = []
      graph.nodes.each do |root|
        next if discovered[root]

        time += 1
        discovered[root] = low[root] = time
        stack = [[root, 0]]
        until stack.empty?
          node, index = stack.last
          neighbors = graph.neighbors(node)
          if index < neighbors.length
            neighbor = neighbors[index]
            stack[-1][1] += 1
            unless discovered[neighbor]
              parent[neighbor] = node
              time += 1
              discovered[neighbor] = low[neighbor] = time
              stack << [neighbor, 0]
              next
            end
            low[node] = [low[node], discovered[neighbor]].min if parent[node] != neighbor
          else
            stack.pop
            ancestor = parent[node]
            next unless ancestor

            low[ancestor] = [low[ancestor], low[node]].min
            result << [ancestor, node].sort.freeze if low[node] > discovered[ancestor]
          end
        end
      end
      result.uniq.sort.freeze
    end

    def degree_centrality(graph)
      denominator = [graph.nodes.length - 1, 1].max.to_f
      graph.nodes.each_with_object({}) do |node, result|
        result[node] = (graph.neighbors(node).length / denominator).round(6)
      end.freeze
    end

    # Exact Brandes for small graphs; deterministic evenly-spaced source sampling
    # bounds work for large personal graphs without changing the API.
    def betweenness_centrality(graph, max_sources: 128)
      nodes = graph.nodes
      return nodes.each_with_object({}) { |node, result| result[node] = 0.0 }.freeze if nodes.length < 3

      sources = sampled_nodes(nodes, max_sources)
      scores = nodes.each_with_object({}) { |node, result| result[node] = 0.0 }
      sources.each do |source|
        stack = []
        predecessors = nodes.each_with_object({}) { |node, result| result[node] = [] }
        sigma = nodes.each_with_object({}) { |node, result| result[node] = 0.0 }
        distance = nodes.each_with_object({}) { |node, result| result[node] = -1 }
        sigma[source] = 1.0
        distance[source] = 0
        queue = [source]
        cursor = 0
        while cursor < queue.length
          vertex = queue[cursor]
          cursor += 1
          stack << vertex
          graph.neighbors(vertex).each do |neighbor|
            if distance[neighbor] < 0
              queue << neighbor
              distance[neighbor] = distance[vertex] + 1
            end
            next unless distance[neighbor] == distance[vertex] + 1

            sigma[neighbor] += sigma[vertex]
            predecessors[neighbor] << vertex
          end
        end
        dependency = nodes.each_with_object({}) { |node, result| result[node] = 0.0 }
        until stack.empty?
          target = stack.pop
          predecessors[target].each do |source_vertex|
            next if sigma[target].zero?

            dependency[source_vertex] += (sigma[source_vertex] / sigma[target]) * (1.0 + dependency[target])
          end
          scores[target] += dependency[target] unless target == source
        end
      end
      scale = nodes.length > sources.length ? nodes.length.to_f / sources.length : 1.0
      normalization = ((nodes.length - 1) * (nodes.length - 2)).to_f
      nodes.each_with_object({}) do |node, result|
        result[node] = ((scores[node] * scale) / normalization).round(6)
      end.freeze
    end

    def communities(graph, max_iterations: 20)
      labels = graph.nodes.each_with_object({}) { |node, result| result[node] = node }
      max_iterations.times do
        changed = false
        graph.nodes.each do |node|
          counts = Hash.new(0)
          graph.neighbors(node).each { |neighbor| counts[labels[neighbor]] += 1 }
          next if counts.empty?

          best_count = counts.values.max
          chosen = counts.select { |_label, count| count == best_count }.keys.sort.first
          next if labels[node] == chosen

          labels[node] = chosen
          changed = true
        end
        break unless changed
      end
      # Canonicalize labels to the smallest member ID for stable external IDs.
      groups = labels.keys.group_by { |node| labels[node] }
      groups.each_value do |members|
        canonical = members.min
        members.each { |member| labels[member] = canonical }
      end
      labels.freeze
    end

    def sampled_nodes(nodes, maximum)
      maximum = maximum.to_i
      return nodes if maximum <= 0 || nodes.length <= maximum

      step = nodes.length.to_f / maximum
      maximum.times.map { |index| nodes[(index * step).floor] }.uniq.freeze
    end
    private_class_method :sampled_nodes
  end
end
