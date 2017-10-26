import UIKit

// MARK: - UITableViewComponentProps

public class UITableComponentProps: UIPropsProtocol {
  /// Represents a table view section.
  public struct Section {
    /// The list of components that are going to be shown in this section.
    public var cells: [UICell]
    /// A node able to render this section header.
    /// - note: Optional.
    public var header: UICell?
    /// 'true' if all of the root nodes in this section have a unique key.
    public var hasDistinctKeys: Bool {
      let set: Set<String> = Set(cells.flatMap { $0.component.key })
      return set.count == cells.count
    }

    public init(cells: [UICell], header: UICell? = nil) {
      self.cells = cells
      self.header = header
    }
  }
  /// The sections that will be presented by this table view instance.
  public var sections: [Section] = []
  /// The table view header component.
  public var header: UIComponentProtocol?
  /// 'true' if all of the root nodes, in all of the sections have a unique key.
  public var hasDistinctKeys: Bool {
    return sections.filter { $0.hasDistinctKeys }.count == sections.count
  }
  /// Returns all of the components across the different sections.
  public var allComponents: [UIComponentProtocol] {
    var components: [UIComponentProtocol] = []
    for section in sections {
      components.append(contentsOf: section.cells.flatMap { $0.component })
    }
    return components
  }

  /// Additional *UITableView* configuration closure.
  /// - note: Use this to configure layout properties such as padding, margin and such.
  public var configuration: (UITableView, CGSize) -> Void = { view, canvasSize in
    view.yoga.width = canvasSize.width
    view.yoga.height = canvasSize.height
  }

  public required init() { }
}

// MARK: - UITableComponent

public typealias UIDefaultTableComponent = UITableComponent<UINilState, UITableComponentProps>

/// Wraps a *UITableView* into a Render component.
public class UITableComponent<S: UIStateProtocol, P: UITableComponentProps>:
  UIComponent<S, P>, UIContextDelegate, UITableViewDataSource, UITableViewDelegate {

  /// The concrete backing view.
  private var tableView: UITableView? {
    return root.renderedView as? UITableView
  }
  private var tableNode: UINodeProtocol!
  private var cellContext: UIContext!

  public required init(context: UIContextProtocol, key: String?) {
    guard let key = key else {
      fatalError("UITableComponent's *key* property is mandatory.")
    }
    super.init(context: context, key: key)
    tableNode = buildTable(context: context)
    cellContext = UICellContext()
    cellContext.registerDelegate(self)
    cellContext._parentContext = context
    context.registerDelegate(self)
  }

  public override func render(context: UIContextProtocol) -> UINodeProtocol {
    return tableNode
  }

  /// Construct the *UITableView* root node.
  private func buildTable(context: UIContextProtocol) -> UINodeProtocol {
    // Init closure.
    func makeTable() -> UITableView {
      let table = UITableView()
      table.dataSource = self
      table.delegate = self
      table.separatorStyle = .none
      return table
    }
    return UINode<UITableView>(reuseIdentifier: "UITableComponent",
                               key: key,
                               create: makeTable) { [weak self] config in
      guard let `self` = self else {
        return
      }
      let table = config.view
      self.props.configuration(table, self.context?.canvasView?.bounds.size ?? .zero)
      /// Implements padding as content insets.
      table.contentInset.bottom = table.yoga.paddingBottom.normal
      table.contentInset.top = table.yoga.paddingTop.normal
      table.contentInset.left = table.yoga.paddingLeft.normal
      table.contentInset.right = table.yoga.paddingRight.normal
    }
  }

  public func setNeedRenderInvoked(on context: UIContextProtocol, component: UIComponentProtocol) {
    cellContext.canvasView = tableView
    root.unmanagedChildren = props.allComponents.map { $0.asNode() }
    // Change comes from one of the parent components.
    if context === self.context {
      // TODO: Integrate IGListDiff algorithm.
      tableView?.reloadData()
    // Change come from one of the children component.
    } else if context === self.cellContext {
      tableView?.beginUpdates()
      tableView?.endUpdates()
    }
  }

  // Returns 'true' if the component passed as argument is a child of this table.
  private func componentIsChild(_ component: UIComponentProtocol) -> Bool {
    for child in props.allComponents {
      if componentIsEqual(child, component) { return true }
    }
    return false
  }

  private func componentIsEqual(_ c1: UIComponentProtocol, _ c2: UIComponentProtocol) -> Bool {
    // Compare pointer identity.
    if c1 === c2 { return true }
    // Compare unique keys.
    if let c1Key = c1.key, let c2Key = c2.key, c1Key == c2Key { return true }
    return false
  }

  /// Asks the data source to return the number of sections in the table view.
  public func numberOfSections(in tableView: UITableView) -> Int {
    return props.sections.count
  }

  /// Tells the data source to return the number of rows in a given section of a table view.
  public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    guard section < props.sections.count else {
      fatalError("Attempts to access to a section out of bounds.")
    }
    return props.sections[section].cells.count
  }

  /// Asks the data source for a cell to insert in a particular location of the table view.
  public func tableView(_ tableView: UITableView,
                        cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let component = props.sections[indexPath.section].cells[indexPath.row].component
    component.delegate = self
    let node = component.asNode()
    let reuseIdentifier = node.reuseIdentifier
    // Dequeue the right cell.
    let cell: UITableComponentCell =
      tableView.dequeueReusableCell(withIdentifier: reuseIdentifier) as? UITableComponentCell
      ?? UITableComponentCell(style: .default, reuseIdentifier: reuseIdentifier)
    // Mounts the new node.
    cell.mount(component: component, width: tableView.bounds.size.width)

    return cell
  }

  public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    let node = props.sections[indexPath.section].cells[indexPath.row].component.asNode()
    node.reconcile(in: UICell.prototype.contentView,
                   size: CGSize(width: tableView.bounds.size.width, height: CGFloat.max),
                   options: [.preventDelegateCallbacks])
    return UICell.prototype.contentView.subviews.first?.bounds.size.height ?? 0
  }

  /// Retrieves the component from the context for the key passed as argument.
  /// If no component is registered yet, a new one will be allocated and returned.
  /// - parameter type: The desired *UIComponent* subclass.
  /// - parameter key: The unique key ('nil' for a transient component).
  /// - parameter props: Configurations and callbacks passed down to the component.
  public func cell<S, P, C: UIComponent<S, P>>(_ type: C.Type,
                                               key: String? = nil,
                                               props: P = P()) -> UICell {
    var component: UIComponentProtocol!
    if let key = key {
      component = cellContext.component(type, key: key, props: props, parent: nil)
    } else {
      component = cellContext.transientComponent(type, props: props, parent: nil)
    }
    return UICell(component: component)
  }
}

// MARK: - UICell

public final class UICell {
  /// The constructed component.
  public let component: UIComponentProtocol
  // Internal constructor.
  init(component: UIComponentProtocol) {
    self.component = component
  }
  // Static internal prototype cell used to calculated components dimensions.
  static let prototype = UITableComponentCell(style: .default, reuseIdentifier: "")
}

/// Components that are embedded in cells have a different context.
public final class UICellContext: UIContext {
  /// Layout animator is not available for cells.
  public override var layoutAnimator: UIViewPropertyAnimator? {
    get { return nil }
    set { }
  }
}

extension UIComponent {
  /// 'true' if this component is being used in a tableview or a collection view.
  var isEmbeddedInCell: Bool {
    return self.context is UICellContext
  }
}

// MARK: - UITableViewComponentCell

public class UITableComponentCell: UITableViewCell {
  /// The node currently associated to this view.
  public var component: UIComponentProtocol?

  public override init(style: UITableViewCellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
  }

  public required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public func mount(component: UIComponentProtocol, width: CGFloat) {
    self.component = component
    component.setCanvas(view: contentView, options: [])
    component.canvasSize = {
      return CGSize(width: width, height: CGFloat.max)
    }
    component.root.reconcile(in: contentView,
                             size: CGSize(width: width, height: CGFloat.max),
                             options: [.preventDelegateCallbacks])

    guard let componentView = contentView.subviews.first else {
      return
    }
    contentView.frame.size = componentView.bounds.size
    contentView.backgroundColor = componentView.backgroundColor
    backgroundColor = componentView.backgroundColor
  }

  /// Asks the view to calculate and return the size that best fits the specified size.
  public override func sizeThatFits(_ size: CGSize) -> CGSize {
    guard let component = component else {
      return .zero
    }
    mount(component: component, width: size.width)
    return contentView.frame.size
  }
}
